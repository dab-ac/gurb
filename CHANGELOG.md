# Changelog

## 1.0.1 — 2026-09-20

### Fixed

- Sort systemd-boot entries by kernel version using `IMAGE_VERSION` in UKI
  metadata. Ubuntu's release text could otherwise put an older kernel first
  (for example, `26.04 LTS` sorts above `26.04.1 LTS`), potentially loading an
  NVIDIA kernel module that no longer matches the installed libraries.
- Preserve signing settings and kernel command-line configuration while
  generating the per-kernel metadata.

### Tests

- Added Perl regression tests for version ordering and configuration handling.
- Verify embedded kernel-version metadata in the kernel-lifecycle VM test.
- All six release VM test suites passed.

### Upgrading

After installing, rebuild all existing UKIs and inspect the boot entries:

```sh
sudo gurb resign all
sudo bootctl list
```

Existing images are not rebuilt automatically. Explicit default and one-shot
boot selections are unchanged. If an earlier entry-token change left duplicate
images, verify replacements before removing obsolete entries.
