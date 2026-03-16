#!/usr/bin/env perl
# test/test-kernel-lifecycle.pl
#
# Tests: --dry-run, resign <version>, kernel install/remove, clean
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

# ── dry-run: resign ──────────────────────────────────────────────────────────

step("Testing --dry-run resign all");
my $before_resign = vm_ssh_ok('sudo find /efi -name "*.efi" -exec sha256sum {} +');
my $dry_out = vm_ssh_ok('sudo gurb --dry-run resign all');
assert_contains('dry-run mentions exec', $dry_out, 'exec:');
my $after_resign = vm_ssh_ok('sudo find /efi -name "*.efi" -exec sha256sum {} +');
assert_contains('no files changed', $after_resign, $before_resign);

# ── dry-run: cmdline ─────────────────────────────────────────────────────────

step("Testing --dry-run cmdline");
my $cmdline_before = vm_ssh_ok('cat /etc/kernel/cmdline');
$work_stream->switch(log_phase("dry-run-cmdline"));
# Change cmdline_extra to trigger a diff
vm_ssh_ok("echo 'cmdline_extra = console=ttyS0,115200 quiet' | sudo tee /etc/gurb/config");
my $dry_cmd = vm_ssh_ok('sudo gurb --dry-run cmdline');
my $cmdline_after = vm_ssh_ok('cat /etc/kernel/cmdline');
chomp($cmdline_before, $cmdline_after);
assert_contains('cmdline unchanged', $cmdline_after, $cmdline_before);
# Restore original config
vm_ssh_ok("echo 'cmdline_extra = console=ttyS0,115200' | sudo tee /etc/gurb/config");

# ── dry-run: generate (skipped — interactive prompt can't be tested via ssh) ──

# ── resign single version ───────────────────────────────────────────────────

step("Testing resign <version>");
my $kver = vm_ssh_ok('uname -r');
chomp $kver;
say "  Current kernel: $kver";

# Find the actual UKI filename (may have machine-id prefix)
my $uki_name = vm_ssh_ok("sudo ls /efi/EFI/Linux/ | grep '$kver'");
chomp $uki_name;
die_msg("No UKI found for $kver") unless $uki_name;
my $uki_path = "/efi/EFI/Linux/$uki_name";
say "  UKI: $uki_path";

# Record current UKI hash
my $uki_before = vm_ssh_ok("sudo sha256sum $uki_path");
# Resign just this version (assert exit code — fails on depmod bug)
my ($resign_out, $resign_rc) = vm_ssh("sudo gurb resign $kver");
assert_contains('resign exits cleanly', ($resign_rc == 0 ? 'ok' : "rc=$resign_rc"), 'ok');
my $uki_after = vm_ssh_ok("sudo sha256sum $uki_path");
# Hash should differ (re-signed with fresh timestamp in PE)
assert_not_contains('UKI re-signed', $uki_after, $uki_before);

# Verify still SIGNED
vm_status_like('status after single resign', 'sudo gurb status', <<~'EXPECT', 'MISSING', 'UNSIGNED');
    ...
    *-generic     [..] SIGNED
    ...
    MOK: enrolled
    ...
EXPECT

# ── kernel install ───────────────────────────────────────────────────────────

step("Finding a second kernel to install");
my $apt_out = vm_ssh_ok('apt-cache search linux-image | grep generic | grep -v unsigned');
my @candidates;
for my $line (split /\n/, $apt_out) {
    if ($line =~ /^(linux-image-(\S+)-generic)\s/) {
        my ($pkg, $ver) = ($1, $2);
        push @candidates, [$pkg, "$ver-generic"] unless "$ver-generic" eq $kver;
    }
}
die_msg("No alternative kernel found") unless @candidates;
# Pick a different version
my ($kern_pkg, $kern_ver) = @{$candidates[0]};
say "  Installing: $kern_pkg ($kern_ver)";

step("Installing second kernel: $kern_pkg");
vm_ssh_ok("sudo apt install -y $kern_pkg");

step("Verifying second kernel UKI created");
my $kern_uki = vm_ssh_ok("sudo ls /efi/EFI/Linux/ | grep '$kern_ver'");
chomp $kern_uki;
die_msg("No UKI found for $kern_ver") unless $kern_uki;
say "  Second UKI: $kern_uki";

vm_status_like('status two kernels', 'sudo gurb status', <<~'EXPECT', 'MISSING', 'UNSIGNED');
    ...
    *-generic     [..] SIGNED
    *-generic     [..] SIGNED
    ...
    MOK: enrolled
    ...
EXPECT

# ── kernel removal ───────────────────────────────────────────────────────────

step("Removing second kernel: linux-image-$kern_ver");
vm_ssh_ok("sudo apt remove -y linux-image-$kern_ver");

step("Verifying UKI removed from ESP");
my ($uki_check, $uki_rc) = vm_ssh("sudo ls /efi/EFI/Linux/ | grep '$kern_ver'");
if ($uki_rc == 0) {
    assert_not_contains('UKI should be gone', 'exists', 'exists');
} else {
    assert_contains('UKI removed', 'removed', 'removed');
}

vm_status_like('status one kernel', 'sudo gurb status', <<~'EXPECT', 'MISSING', 'UNSIGNED');
    ...
    *-generic     [..] SIGNED
    ...
    MOK: enrolled
    ...
EXPECT

# ── clean ────────────────────────────────────────────────────────────────────

step("Testing gurb clean");
$work_stream->switch(log_phase("clean"));
# clean is interactive — run via tmux, answer 'n' to any delete prompts
tmux_send(VMTest::tmux_work(), ssh_cmd_str('sudo gurb clean'), 'Enter');
my $clean_out = $work_stream->wait_stable(3, 30);
$clean_out //= $work_stream->read_all();
$clean_out = strip_ansi($clean_out);
log_output("clean output", $clean_out);

# Our MOK should show as KEEP (it signs our binaries)
assert_contains('MOK marked KEEP', $clean_out, 'KEEP');
assert_not_contains('no UNUSED MOKs', $clean_out, 'UNUSED');

vm_destroy();
done();
