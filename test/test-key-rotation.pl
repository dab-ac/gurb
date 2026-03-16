#!/usr/bin/env perl
# test/test-key-rotation.pl
#
# Tests: generate new key → enroll → MokManager → resign → clean old MOK
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

# ── record original key fingerprint ──────────────────────────────────────────

step("Recording original MOK fingerprint");
my $orig_fp = vm_ssh_ok('sudo openssl x509 -in /var/lib/shim-signed/mok/MOK.pem -fingerprint -sha256 -noout');
chomp $orig_fp;
say "  Original: $orig_fp";

# ── generate new key (overwrites existing) ───────────────────────────────────

step("Generating new MOK key (key rotation)");
$work_stream->switch(log_phase("key-rotation-generate"));

# gurb generate asks "Key already exists ... Overwrite? [y/N]"
tmux_send(VMTest::tmux_work(), ssh_cmd_str('sudo gurb generate'), 'Enter');
$work_stream->wait_for(qr/Overwrite\?/i, 30)
    // die_msg("never saw overwrite prompt");
tmux_send(VMTest::tmux_work(), 'y', 'Enter');

# Then mokutil import asks for password twice
$work_stream->wait_for(qr/input password/i, 30)
    // die_msg("never saw mokutil password prompt");
tmux_send(VMTest::tmux_work(), 'gurbgurb', 'Enter');
$work_stream->wait_for(qr/input password again/i, 15)
    // die_msg("never saw second password prompt");
tmux_send(VMTest::tmux_work(), 'gurbgurb', 'Enter');
$work_stream->wait_stable(2, 30);

step("Verifying new key is different");
my $new_fp = vm_ssh_ok('sudo openssl x509 -in /var/lib/shim-signed/mok/MOK.pem -fingerprint -sha256 -noout');
chomp $new_fp;
say "  New: $new_fp";
assert_not_contains('key rotated', $new_fp, $orig_fp);

step("Verifying new MOK is pending");
vm_status_like('new MOK pending', 'sudo gurb status', <<~'EXPECT');
    ...
    MOK: [..]pending[..]
    ...
EXPECT

# ── resign with new key ─────────────────────────────────────────────────────

step("Resigning all with new key (--force, pending enrollment)");
my ($resign_out, $resign_rc) = vm_ssh('sudo gurb resign --force all');
assert_contains('resign --force all exits cleanly', ($resign_rc == 0 ? 'ok' : "rc=$resign_rc"), 'ok');

# Binaries are now signed with new key (not yet enrolled)
vm_status_like('status after resign', 'sudo gurb status', <<~'EXPECT');
    ...
    shim          [..] OK
    ...
    systemd-boot  [..] OK
    ...
    *-generic     [..] OK
    ...
    MOK: [..]pending[..]
    ...
EXPECT

# ── reboot for MokManager enrollment of new key ─────────────────────────────

mok_enroll($console_stream, 'gurbgurb');

# ── verify new key works ─────────────────────────────────────────────────────

$console_stream->switch(log_phase("key-rotation-verify"));

step("Verifying boot with new key");
vm_status_like('cmdline', 'cat /proc/cmdline', '[..]console=ttyS0,115200[..]');
vm_status_like('secure boot', 'mokutil --sb-state', 'SecureBoot enabled');
vm_status_like('status new key', 'sudo gurb status', <<~'EXPECT', 'MISSING', 'UNSIGNED');
    ...
    shim          [..] OK
    ...
    systemd-boot  [..] OK
    ...
    *-generic     [..] OK
    ...
    MOK: [..]enrolled
    ...
EXPECT

# ── clean: old MOK should show as UNUSED ─────────────────────────────────────

step("Testing gurb clean (old MOK should be UNUSED)");
$work_stream->switch(log_phase("key-rotation-clean"));
tmux_send(VMTest::tmux_work(), ssh_cmd_str('sudo gurb clean'), 'Enter');

# Answer 'n' to each delete prompt to iterate through all MOKs
for (1..10) {
    my $chunk = $work_stream->wait_for(qr/Delete.*\[y\/N\]|KEEP/, 15);
    last unless $chunk && $chunk =~ /Delete/;
    tmux_send(VMTest::tmux_work(), 'n', 'Enter');
}
my $clean_out = strip_ansi($work_stream->read_all());
log_output("clean output", $clean_out);

assert_contains('old MOK is UNUSED', $clean_out, 'UNUSED');
assert_contains('current MOK is KEEP', $clean_out, 'KEEP');

vm_destroy();
done();
