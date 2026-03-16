# Testing

## Prerequisites

Enter the nix devshell (`nix develop` or direnv). Provides `qemu`, `OVMF_FV`,
`xorriso`, `virtiofsd`.

## VM infrastructure

```bash
test/vm create plucky   # Ubuntu 25.04 (Plucky) — default
test/vm start
test/vm wait            # block until SSH is up
test/vm ssh [command]   # run command in guest
test/vm stop            # graceful ACPI shutdown via QMP
test/vm destroy         # kills QEMU + virtiofsd, removes tmux session
```

Console: `tmux attach -t gurb-vm`

### VM configuration

| Resource | Value |
|----------|-------|
| Machine | q35 + SMM, KVM, UEFI Secure Boot (Microsoft keys) |
| CPU | 6 vCPU (`-cpu host`), override with `VM_SMP=` |
| RAM | 3 GB (memfd-backed for virtiofs shared memory), override with `VM_RAM=` |
| Disk | 8G qcow2 overlay, `cache=unsafe` |
| Network | user-mode, SSH port-forwarded to random host port |

### Shared mounts (virtiofs)

| Tag | Host path | Guest mount | Mode |
|-----|-----------|-------------|------|
| `hostpkg` | `pkg/` | `/mnt` (manual) | read-only |
| `hostaptcache` | `test/apt-cache/` | `/var/cache/apt/archives` (cloud-init) | read-write |

The apt cache persists across VM runs — first run downloads packages from the
network, subsequent runs use cached .debs.

### Cloud-init setup

- ESP mounted at `/efi` (fstab rewritten from `/boot/efi`)
- `/boot/efi` bind-mounted to `/efi` (needed for `do-release-upgrade`)
- Secure Boot enforcing: `mokutil --sb-state` → `SecureBoot enabled`

## Automated tests

All tests share common setup via `VMTest::Setup` (boot VM, install gurb,
MOK enrollment with password `gurbgurb`). Each boots a fresh VM.

### GRUB purge + upgrade (~10 min)

```bash
test/test-grub-purge-upgrade.pl
```

Full end-to-end: install gurb, enroll MOK, sign, purge GRUB, reboot,
`do-release-upgrade` to Questing, verify everything survives.

### Secure Boot enforcement (~15 min)

```bash
test/test-secure-boot.pl
```

Three trust-chain boundaries: (A) re-sign systemd-boot with bad key — shim
rejects, (B) re-sign UKI with bad key — shim rejects, (C) build unsigned
kernel module — lockdown rejects. Each test recovers by power-cycling with
Secure Boot OFF, re-signing with MOK, and rebooting with SB ON.

### Kernel lifecycle (~12 min)

```bash
test/test-kernel-lifecycle.pl
```

`--dry-run` modes, `resign <version>`, kernel install/remove (UKI
created/removed on ESP), `gurb clean`.

### Uninstall/reinstall (~12 min)

```bash
test/test-uninstall-reinstall.pl
```

`apt remove` (diversion restored), reinstall (MOK key survives), `apt purge`
(config removed), full roundtrip.

### Key rotation (~15 min)

```bash
test/test-key-rotation.pl
```

Generate new key, resign, MokManager enrollment, `gurb clean` (old MOK
detected as UNUSED).

### Fallback boot path (~12 min)

```bash
test/test-fallback-boot.pl
```

`shim=/efi/EFI/BOOT/BOOTX64.EFI` config, reinstall, verify boot from
fallback path.

## MokManager serial navigation

When manually navigating MokManager via tmux (`tmux send-keys -t gurb-vm:0`):

- Spam **Up** arrow to catch the 10s "Press any key" prompt
- Do NOT spam Enter (selects "Continue boot"), Space, or Escape
- Flow: Down Enter (Enroll MOK) → Down Enter (Continue) → Down Enter (Yes) → type password Enter → Enter (Reboot)
- If you miss the timeout, MokManager consumes the pending enrollment — must re-run `mokutil --import`

## Gotchas

- `do-release-upgrade` hardcodes `/boot/efi` check against `/proc/mounts` — symlinks don't work, must be a real mount (cloud-init handles this)
- If `/boot/grub/x86_64-efi/core.efi` exists, `shim-signed` postinst fails trying to run `grub-multi-install` — purge grub-common and `rm -rf /boot/grub`
