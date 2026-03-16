# gurb

Replaces GRUB with systemd-boot under shim on Ubuntu, managing the full
Secure Boot signing lifecycle via a single local package.

## What this package does

- **Provides** `grub-efi-amd64-signed`, `grub2-common`, `grub-common` as dummy
  satisfiers so `shim-signed` installs without pulling in GRUB
- **Coexists** with GRUB during transition — no Conflicts, user purges manually
  once verified working
- **Diverts** `/etc/kernel/postinst.d/dracut` (from the `dracut` package) to
  `/etc/kernel/postinst.d/dracut.distrib`; replaces it with an exit-0 no-op
- **Installs** `/etc/kernel/install.conf` configuring `kernel-install` for UKI
  layout, `dracut` as initrd generator, `ukify` as UKI assembler, no
  machine-id prefix in UKI filenames, `BOOT_ROOT=/efi`
- **Installs** `/etc/kernel/install.d/05-vmlinuz-symlink.install` creating
  `/usr/lib/modules/$kver/vmlinuz` symlinks so `kernel-install add $kver
  /usr/lib/modules/$kver/vmlinuz` works and manual no-arg invocation works
- **Installs** `/etc/kernel/postinst.d/zz-gurb` and matching `postrm.d`
  calling `kernel-install add $kver $image` / `kernel-install remove $kver`
- **Installs** `/etc/kernel/uki.conf` configuring `ukify` to sign UKIs with
  `sbsign` using key paths that `gurb` also reads for all signing
- **Registers dpkg file triggers** on `shimx64.efi.signed.latest`, `mmx64.efi`,
  and `systemd-bootx64.efi` to copy/sign updated binaries to the ESP
  automatically when upstream packages upgrade
- **Provides** `gurb(8)` CLI — run `man gurb` after installation

## Quickstart

```bash
# ESP must be mounted at /efi (or set shim= in /etc/gurb.conf)
apt install ./gurb.deb
gurb generate                  # creates MOK key, queues enrollment
gurb cmdline                   # generates /etc/kernel/cmdline from dracut
gurb resign --force all        # signs systemd-boot + builds UKIs
gurb bootentry                 # creates EFI NVRAM entry
efibootmgr --bootorder XXXX,...     # put our entry first
reboot                              # MokManager: Enroll MOK → Continue → Yes → password → Reboot
gurb status                    # everything should say SIGNED, MOK: enrolled
apt purge grub-common grub-efi-amd64-signed grub2-common && rm -rf /boot/grub
```

## Configuration

See `man gurb` for full configuration and command reference.

## Uninstall

`apt remove gurb` removes the package but preserves:
- `/etc/gurb.conf` — configuration (dpkg conffile, preserved on remove)
- `/var/lib/shim-signed/mok/` — MOK signing key, certificate, and DER
- ESP files (`/efi/EFI/systemd/`) — shim, systemd-boot, UKIs

`apt purge gurb` additionally removes conffiles (`/etc/gurb.conf`,
`/etc/kernel/uki.conf`, `/etc/kernel/install.conf`, hooks), but the MOK key
survives (it lives in `/var/lib/`, outside dpkg conffile tracking). This is
intentional — the MOK is enrolled in UEFI firmware and deleting the private
key would make it impossible to re-sign binaries without full MokManager
re-enrollment.

## Key and certificate

One key, one MOK enrollment, serves three purposes:

1. **EFI binary signing** — shim verifies systemd-boot (installed as
   `grubx64.efi`) against the MOK database before chainloading it
2. **UKI signing** — systemd-boot verifies UKIs via the ShimLock protocol
   (`shim_lock->shim_verify`); shim checks against MOK
3. **Kernel module signing** — the kernel's module loader checks signatures
   against keys loaded at boot from the MOK database

The certificate uses `extendedKeyUsage = codeSigning` only.

**Coexistence with Ubuntu's DKMS MOK:** Ubuntu's `update-secureboot-policy`
(from `shim-signed`) creates a MOK at the same path (`/var/lib/shim-signed/mok/`)
with the modsign OID (`1.3.6.1.4.1.2312.16.1.2`). Shim explicitly blacklists
that OID for EFI binary verification — the DKMS key can only sign kernel modules,
not bootloaders or UKIs. `gurb generate` detects an existing key, displays its
properties (including the modsign OID warning), and asks before overwriting.
Both keys can coexist in MOK NVRAM but they cannot share the same file path.

**Fallback boot path (`\EFI\BOOT\BOOTX64.EFI`):** Set `shim=/efi/EFI/BOOT/BOOTX64.EFI`
in `/etc/gurb.conf` to install shim to the UEFI fallback path. If the cloud image
or a previous OS left `fbx64.efi` (shim's fallback binary) in that directory,
remove it — shim chains to fbx64 when loaded from `\EFI\BOOT\`, and without
`BOOT*.CSV` files it enters a reset loop. `gurb status` warns about this.

**Why not the modsign OID (`1.3.6.1.4.1.2312.16.1.2`)?**
Shim's `verify_eku()` (in `shim.c`) explicitly **blacklists** any certificate
containing that OID — it iterates the EKU extension and returns FALSE
immediately on a match, before `AuthenticodeVerify` is ever called. The OID
exists to let you create a key the kernel accepts for modules but that shim
rejects for EFI binaries. The kernel does not require or check for the modsign
OID: it is absent from `certs/default_x509.genkey` and from the kernel OID
registry entirely. `codeSigning` alone satisfies all three verifiers.

**Why not `systemd-sbsign`?**
The `SystemdSbSign` backend in `ukify.py` raises `NotImplementedError` in its
`verify()` method — it cannot check whether a PE binary is already signed
before deciding whether to re-sign it. The `SbSign` backend works correctly.
We set `SecureBootSigningTool=sbsign` in `uki.conf`.

**Canonical's certificate** is compiled into the shim binary as `vendor_cert`
(via `VENDOR_CERT_FILE` at build time). It is not stored in MOK NVRAM.
`gurb clean` does not need to preserve it.

## kernel-install + dracut + ukify call graph

```
kernel package postinst
  └─ /etc/kernel/postinst.d/zz-gurb         (this package)
       └─ kernel-install add $kver $image
            ├─ /etc/kernel/install.d/05-vmlinuz-symlink.install
            │    └─ ln -sf $image /usr/lib/modules/$kver/vmlinuz
            ├─ /usr/lib/kernel/install.d/50-dracut.install      (dracut)
            │    KERNEL_INSTALL_INITRD_GENERATOR=dracut → proceed
            │    KERNEL_INSTALL_IMAGE_TYPE != uki        → proceed
            │    KERNEL_INSTALL_UKI_GENERATOR=ukify      → --no-uefi mode
            │    └─ dracut --no-uefi --kver $kver $STAGING_AREA/initrd
            ├─ /usr/lib/kernel/install.d/60-ukify.install       (systemd)
            │    KERNEL_INSTALL_LAYOUT=uki          → proceed
            │    KERNEL_INSTALL_UKI_GENERATOR=ukify → proceed
            │    reads /etc/kernel/uki.conf         → SecureBootSigningTool=sbsign
            │    reads /etc/kernel/cmdline
            │    reads $STAGING_AREA/initrd
            │    └─ ukify build → sbsign → $STAGING_AREA/uki.efi
            └─ /usr/lib/kernel/install.d/90-uki-copy.install    (systemd)
                 └─ cp uki.efi → /efi/EFI/Linux/$kver.efi
```

`/etc/kernel/postinst.d/dracut` (Ubuntu's legacy hook from the dracut package)
is diverted to `/etc/kernel/postinst.d/dracut.distrib` and replaced with an
exit-0 no-op. Without this it would run alongside `zz-gurb` and generate
a redundant `/boot/initrd.img-$kver` that is never used.

`/etc/kernel/entry-token` is set to `gurb`, giving UKI filenames like
`gurb-6.14.0-37-generic.efi`. Without this, kernel-install uses the
machine-id as a prefix (`c84b2b4b…-6.14.0-37-generic.efi`).
`MACHINE_ID=none` in `install.conf` does not work on systemd 257 —
`sd_id128_from_string("none")` fails and the setting is silently ignored.

The vmlinuz symlink at `/usr/lib/modules/$kver/vmlinuz` is needed because
Ubuntu inexplicably installs kernels to `/boot/vmlinuz-$kver` instead of the
standard `/usr/lib/modules/$kver/vmlinuz` that `kernel-install` expects.
`verb_add()` with zero args defaults version to `uname -r`, then
`kernel_from_version()` looks up `/usr/lib/modules/$ver/vmlinuz` — which
doesn't exist on Ubuntu without our symlink. The two-arg form
`kernel-install add $kver /path/to/vmlinuz` bypasses `kernel_from_version()`
entirely (relative paths are resolved against cwd via
`path_make_absolute_cwd()`). The one-arg form `kernel-install add $thing` is
simply broken — it treats `$thing` as a kernel image path but hardcodes
version to `uname -r`, silently ignoring whatever you actually pointed at.
Our hooks always use the explicit two-arg form.

**Why `gurb resign` scans `/boot/vmlinuz-*` instead of
`/usr/lib/modules/*/vmlinuz`:** `05-vmlinuz-symlink.install` runs as part of
`kernel-install add`, creating `/usr/lib/modules/$kver/vmlinuz` → `$image`.
If `gurb resign` discovers kernels via the symlink path and passes it back to
`kernel-install add`, the hook receives the symlink as `$KERNEL_IMAGE` and
runs `ln -sf /usr/lib/modules/$kver/vmlinuz /usr/lib/modules/$kver/vmlinuz` —
a self-referential symlink. Subsequent `depmod` and `ukify` fail with ELOOP.
Scanning `/boot/vmlinuz-*` (the canonical location Ubuntu actually installs
to) avoids this entirely: `kernel-install` receives an absolute path to a
real file, and the symlink hook creates a correct symlink pointing back at it.

## ESP layout

```
/efi/EFI/systemd/           (or wherever 'shim' points in config)
  shimx64.efi               ← /usr/lib/shim/shimx64.efi.signed.latest
  mmx64.efi                 ← /usr/lib/shim/mmx64.efi
  grubx64.efi               ← sbsign(/usr/lib/systemd/boot/efi/systemd-bootx64.efi)

/efi/EFI/Linux/
  $kver.efi                 ← built by ukify, signed via uki.conf
```

Shim's `DEFAULT_LOADER` (in `shim.h`) is `\grubx64.efi`, resolved relative to
the directory shim was loaded from. This is why systemd-boot is named
`grubx64.efi`. On a recovery partition loaded via firmware F-key, shim's
`is_removable_media_path()` detects the `\EFI\BOOT\BOOT*` load path and
ignores all NVRAM load options (Ubuntu builds shim with
`DISABLE_REMOVABLE_LOAD_OPTIONS=1`). `DEFAULT_LOADER` is always used and
cannot be overridden on that path.

## Research

See [RESEARCH.md](RESEARCH.md) for source-level findings from shim, systemd,
dracut, and the Linux kernel.
