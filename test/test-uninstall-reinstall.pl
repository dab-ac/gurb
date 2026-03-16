#!/usr/bin/env perl
# test/test-uninstall-reinstall.pl
#
# Tests: apt remove vs apt purge, re-install after uninstall roundtrip
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

# ── apt remove ───────────────────────────────────────────────────────────────

step("apt remove gurb");
vm_ssh_ok('sudo apt remove -y gurb');

step("Verifying postrm undid dracut diversion");
# After remove, the diversion should be restored
my ($div_out) = vm_ssh('dpkg-divert --listpackage /etc/kernel/postinst.d/dracut');
assert_not_contains('no active diversion', $div_out, 'gurb');

# The original dracut postinst.d script should be restored
vm_check('test -f /etc/kernel/postinst.d/dracut && echo DRACUT_RESTORED', 'DRACUT_RESTORED');

step("Verifying config files still present after remove");
# apt remove preserves conffiles — /etc/gurb/config should remain
vm_check('test -f /etc/gurb/config && echo CONFIG_EXISTS', 'CONFIG_EXISTS');

step("Verifying ESP files left behind (by design)");
my ($esp_out) = vm_ssh('sudo ls /efi/EFI/systemd/ 2>&1');
assert_contains('ESP dir exists after remove', $esp_out, 'grubx64.efi');

# ── reinstall after remove ───────────────────────────────────────────────────

step("Reinstalling gurb after remove");
vm_ssh_ok('mountpoint -q /mnt || sudo mount -t virtiofs hostpkg /mnt');
vm_ssh_ok('dpkg-deb -b /mnt /tmp/gurb.deb');
vm_ssh_ok('sudo apt install -y /tmp/gurb.deb');

step("Verifying reinstall: diversion active, status OK");
my ($div_out2) = vm_ssh('dpkg-divert --listpackage /etc/kernel/postinst.d/dracut');
assert_contains('diversion active', $div_out2, 'gurb');

# MOK key should still be present from before (remove doesn't delete /var/lib)
vm_status_like('status after reinstall', 'sudo gurb status', <<~'EXPECT', 'MISSING', 'UNSIGNED');
    ...
    shim          [..] SIGNED
    ...
    systemd-boot  [..] SIGNED
    *-generic     [..] SIGNED
    ...
    MOK: enrolled
    ...
EXPECT

# ── apt purge ────────────────────────────────────────────────────────────────

step("apt purge gurb");
vm_ssh_ok('sudo apt purge -y gurb');

step("Verifying postrm undid dracut diversion");
my ($div_out3) = vm_ssh('dpkg-divert --listpackage /etc/kernel/postinst.d/dracut');
assert_not_contains('no active diversion', $div_out3, 'gurb');

step("Verifying config files after purge");
# /etc/gurb/config is user-created (via tee in test), not a dpkg conffile.
# It survives purge — this is correct behavior.
vm_check('test -f /etc/gurb/config && echo CONFIG_EXISTS', 'CONFIG_EXISTS');

# uki.conf and install.conf are in /etc/kernel/ (conffiles of gurb)
my ($uki_check, $uki_rc) = vm_ssh('test -f /etc/kernel/uki.conf');
if ($uki_rc != 0) {
    assert_contains('uki.conf removed', 'removed', 'removed');
} else {
    assert_not_contains('uki.conf should be gone', 'exists', 'exists');
}

step("Verifying ESP files left behind (by design)");
my ($esp_out2) = vm_ssh('sudo ls /efi/EFI/systemd/ 2>&1');
assert_contains('ESP dir exists after purge', $esp_out2, 'grubx64.efi');

# ── full reinstall after purge ───────────────────────────────────────────────

step("Reinstalling gurb after purge (full roundtrip)");
vm_ssh_ok('mountpoint -q /mnt || sudo mount -t virtiofs hostpkg /mnt');
vm_ssh_ok('dpkg-deb -b /mnt /tmp/gurb.deb');
vm_ssh_ok('sudo apt install -y /tmp/gurb.deb');

step("Verifying reinstall basics");
my ($div_out4) = vm_ssh('dpkg-divert --listpackage /etc/kernel/postinst.d/dracut');
assert_contains('diversion active', $div_out4, 'gurb');

# After purge+reinstall, MOK key survives (lives in /var/lib, not a conffile)
vm_status_like('status after purge+reinstall', 'sudo gurb status', <<~'EXPECT');
    ...
    shim [..] SIGNED
    ...
    Key: [..]
    ...
EXPECT

step("Re-generating MOK key after purge+reinstall (key survives purge)");
$work_stream->switch(log_phase("reinstall-generate"));
tmux_send(VMTest::tmux_work(), ssh_cmd_str('sudo gurb generate'), 'Enter');
# Key already exists — generate shows key info and asks to overwrite
$work_stream->wait_for(qr/Overwrite\?/i, 30)
    // die_msg("never saw overwrite prompt (existing key should survive purge)");
tmux_send(VMTest::tmux_work(), 'y', 'Enter');
$work_stream->wait_for(qr/input password/i, 15)
    // die_msg("never saw mokutil password prompt");
tmux_send(VMTest::tmux_work(), 'gurbgurb', 'Enter');
$work_stream->wait_for(qr/input password again/i, 15)
    // die_msg("never saw second password prompt");
tmux_send(VMTest::tmux_work(), 'gurbgurb', 'Enter');
$work_stream->wait_stable(2, 30);

step("Signing and verifying after reinstall");
my ($resign_out, $resign_rc) = vm_ssh('sudo gurb resign --force all');
assert_contains('resign --force all exits cleanly', ($resign_rc == 0 ? 'ok' : "rc=$resign_rc"), 'ok');

vm_status_like('status post-resign', 'sudo gurb status', <<~'EXPECT');
    ...
    shim          [..] SIGNED
    ...
    systemd-boot  [..] SIGNED
    *-generic     [..] SIGNED
    ...
    MOK: pending
    ...
EXPECT

vm_destroy();
done();
