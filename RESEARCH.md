# Research notes

Source-level findings from the packages gurb interacts with.

## Packages

| Package | Version | Link |
|---|---|---|
| shim | 15.8-0ubuntu2 | https://launchpad.net/ubuntu/+source/shim/15.8-0ubuntu2 |
| shim-signed | 1.59 | https://launchpad.net/ubuntu/+source/shim-signed/1.59 |
| systemd | 257.9-0ubuntu2.1 | https://launchpad.net/ubuntu/+source/systemd/257.9-0ubuntu2.1 |
| dracut | 108-3ubuntu3 | https://launchpad.net/ubuntu/+source/dracut/108-3ubuntu3 |
| linux | 6.17.0-14.14 | https://launchpad.net/ubuntu/+source/linux/6.17.0-14.14 |

## Key findings by file

**`shim.c` + `shim.h` (shim)**
- `verify_eku()` — blacklists modsign OID; returns FALSE if found in EKU
- `OID_EKU_MODSIGN` — `"1.3.6.1.4.1.2312.16.1.2"`
- `DEFAULT_LOADER` — hardcoded `\grubx64.efi`
- `is_removable_media_path()` — detects `\EFI\BOOT\BOOT*`, disables load option override
- `parse_load_options()` (in `load-options.c`) — sets `second_stage` from NVRAM when not on removable path

**`Cryptlib/Pk/CryptPkcs7Verify.c` (shim)**
- `X509VerifyCb()` — accepts `XKU_CODE_SIGN (0x8)` as recovery for `X509_V_ERR_INVALID_PURPOSE`; uses `==` (not `&`), so any additional *standard* EKU (e.g. `clientAuth`) would cause the check to fail; unrecognized OIDs like the modsign OID are invisible to OpenSSL's bitmask

**`update-secureboot-policy` (shim-signed)**
- `SB_KEY`, `SB_PRIV` — default paths under `/var/lib/shim-signed/mok/`
- `create_mok()` — generates key with `codeSigning` + modsign OID; `verify_eku()` blacklists the modsign OID, so this key cannot verify EFI binaries

**`postinst` (shim-signed)**
- `find_revoked()` — calls `is-not-revoked` on kernels ≥ running version
- `/usr/lib/grub/grub-multi-install` — guarded by `[ -e /boot/grub/$arch/core.efi ]`; never runs in our setup

**`kernel-install.c` (systemd)**
- `kernel_from_version()` — looks up `/usr/lib/modules/$ver/vmlinuz`
- `verb_add()` — 1 arg = kernel image path (not version); 2 args = version + path

**`src/boot/shim.c` (systemd)**
- `shim_load_image()` — installs `shim_validate` security override
- `shim_validate()` — calls `shim_lock->shim_verify()` via ShimLock protocol

**`src/ukify/ukify.py` (systemd)**
- `SystemdSbSign.verify()` — raises `NotImplementedError`
- `SbSign.verify()` — implemented correctly
- Config keys: `UKI/SecureBootSigningTool`, `UKI/SecureBootPrivateKey`, `UKI/SecureBootCertificate`
- `uki_conf_location()` — searches `/etc/kernel/uki.conf` first

**`install.d/50-dracut.install` (dracut)**
- Exits if `KERNEL_INSTALL_IMAGE_TYPE=uki`
- Respects `KERNEL_INSTALL_INITRD_GENERATOR` and `KERNEL_INSTALL_UKI_GENERATOR`
- With our settings: generates initrd only, leaves UKI assembly to ukify

**`debian/kernel/postinst.d/dracut` (dracut, Ubuntu-specific)**
- Calls `dracut -q --force /boot/initrd.img-$version $version`
- Entirely separate from the upstream `install.d/50-dracut.install` plugin
- We divert this file to a no-op

**`certs/default_x509.genkey` (linux)**
- `keyUsage=digitalSignature` only; no `extendedKeyUsage`
- Confirms kernel module signing does not check EKU

**`include/linux/oid_registry.h` (linux)**
- `OID_extKeyUsage` defined but never referenced in any signing code path
- Modsign OID absent from the kernel OID registry entirely
