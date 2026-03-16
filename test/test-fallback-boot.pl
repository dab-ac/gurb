#!/usr/bin/env perl
# test/test-fallback-boot.pl
#
# Tests: UEFI fallback boot — firmware discovers \EFI\BOOT\BOOTX64.EFI
#
# Installs shim to the fallback path, deletes fbx64.efi (which would cause
# shim to chain to it instead of systemd-boot), clears all Boot#### entries,
# and lets OVMF's PlatformRecovery discover the fallback bootloader.
#
# Prerequisites: nix devshell (provides OVMF_FV, qemu, xorriso, tmux, virtiofsd)
use v5.40;
use FindBin;
use File::Basename qw(dirname);
use lib "$FindBin::Bin/lib";
use VMTest;
use VMTest::Setup;

my $SCRIPT_DIR  = $FindBin::Bin;
my $PROJECT_DIR = dirname($SCRIPT_DIR);

VMTest::init(ssh_dir => $SCRIPT_DIR);

chdir $PROJECT_DIR or die "chdir $PROJECT_DIR: $!";
log_init();

my $ctx = setup_gurb(script_dir => $SCRIPT_DIR);
my ($console_stream, $work_stream) = @{$ctx}{qw(console_stream work_stream)};

# Purge GRUB
step("Purging GRUB");
vm_ssh('sudo apt purge -y grub-common grub-efi-amd64-signed grub2-common grub-pc');
vm_ssh_ok('sudo rm -rf /boot/grub');

# ── install shim to fallback path ────────────────────────────────────────────

step("Configuring fallback boot path");
vm_ssh_ok("sudo tee /etc/gurb.conf <<'EOF'
shim=/efi/EFI/BOOT/BOOTX64.EFI
cmdline_extra=console=ttyS0,115200
EOF");

step("Reinstalling gurb to trigger postinst with fallback config");
vm_ssh_ok('mountpoint -q /mnt || sudo mount -t virtiofs hostpkg /mnt');
vm_ssh_ok('dpkg-deb -b /mnt /tmp/gurb.deb');
vm_ssh_ok('sudo dpkg -i /tmp/gurb.deb');

step("Verifying shim at fallback path");
vm_check('sudo test -f /efi/EFI/BOOT/BOOTX64.EFI && echo SHIM_EXISTS', 'SHIM_EXISTS');
vm_check('sudo test -f /efi/EFI/BOOT/mmx64.efi && echo MM_EXISTS', 'MM_EXISTS');
vm_check('sudo test -f /efi/EFI/BOOT/grubx64.efi && echo SDBOOT_EXISTS', 'SDBOOT_EXISTS');

step("Re-signing all kernels with fallback path config");
my ($resign_out, $resign_rc) = vm_ssh('sudo gurb resign all');
assert_contains('resign all exits cleanly', ($resign_rc == 0 ? 'ok' : "rc=$resign_rc"), 'ok');

step("Verifying status with fallback path");
vm_status_like('status fallback', 'sudo gurb status', <<~'EXPECT', 'MISSING', 'UNSIGNED');
    ...
    shim          [..]/EFI/BOOT/BOOTX64.EFI [..] OK
    ...
    systemd-boot  [..]/EFI/BOOT/grubx64.efi [..] OK
    ...
    MOK: [..]enrolled
    ...
EXPECT

# ── prepare for firmware fallback discovery ──────────────────────────────────

# fbx64.efi (fallback.efi from cloud image) causes shim to chain to it instead
# of systemd-boot. Without BOOT*.CSV files it just calls ResetSystem() in a loop.
step("Removing fbx64.efi");
vm_ssh_ok('sudo rm -f /efi/EFI/BOOT/fbx64.efi');

step("Deleting all boot entries to force firmware fallback");
my $efi_out = vm_ssh_ok('sudo efibootmgr');
my @entries = parse_efi_entries($efi_out);
for my $entry (@entries) {
    vm_ssh_ok("sudo efibootmgr --delete-bootnum --bootnum $entry->{num}");
}
say "  Deleted " . scalar(@entries) . " boot entries";

# ── reboot — firmware should discover \EFI\BOOT\BOOTX64.EFI ─────────────────

step("Rebooting for firmware fallback discovery");
$console_stream->switch(log_phase("fallback-boot-console"));
vm_ssh('sudo reboot');
wait_ssh(180);

step("Verifying fallback boot");
vm_status_like('cmdline', 'cat /proc/cmdline', '[..]console=ttyS0,115200[..]');
vm_status_like('secure boot', 'mokutil --sb-state', 'SecureBoot enabled');
vm_status_like('status post-fallback-boot', 'sudo gurb status', <<~'EXPECT', 'MISSING', 'UNSIGNED');
    ...
    shim          [..]/EFI/BOOT/BOOTX64.EFI [..] OK
    ...
    systemd-boot  [..]/EFI/BOOT/grubx64.efi [..] OK
    ...
    *-generic     [..] OK
    ...
    MOK: [..]enrolled
    ...
EXPECT

vm_destroy();
done();
