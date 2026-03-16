#!/usr/bin/env perl
# test/test-grub-purge-upgrade.pl
#
# Integration test: Plucky VM → install gurb → MOK enrollment →
# grub purge → reboot → do-release-upgrade to Questing → verify
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

# Verify GRUB coexistence before purge
vm_status_like('grub still present', 'sudo gurb status', <<~'EXPECT');
    ...
    GRUB is still installed [..]
    ...
EXPECT

# ── purge GRUB ───────────────────────────────────────────────────────────────

step("Purging GRUB packages");
vm_ssh('sudo apt purge -y grub-common grub-efi-amd64-signed grub2-common grub-pc');
vm_ssh_ok('sudo rm -rf /boot/grub');

step("Verifying GRUB removed");
vm_status_like('status post-grub-purge', 'sudo gurb status', <<~'EXPECT',
    ...
    shim          [..] OK
    ...
    mm            [..] OK
    systemd-boot  [..] OK
    ...
    *-generic     [..] OK
    ...
    MOK: [..]enrolled
EXPECT
    'MISSING', 'GRUB');

# ── reboot without GRUB ─────────────────────────────────────────────────────

step("Rebooting without GRUB — boot success = SSH comes up");
$console_stream->switch(log_phase("no-grub-console"));
vm_ssh('sudo reboot');
wait_ssh(180);

# ── do-release-upgrade ───────────────────────────────────────────────────────

step("Installing gpg and updating packages");
vm_ssh_ok('sudo apt install -y gpg');
vm_ssh_ok('sudo apt-get update -qq && sudo apt-get upgrade -y');

step("Starting do-release-upgrade via tmux");
$work_stream->switch(log_phase("do-release-upgrade"));
tmux_send(tmux_work(),
    ssh_cmd_str('sudo do-release-upgrade -f DistUpgradeViewNonInteractive'),
    'Enter');

step("Waiting for do-release-upgrade (up to 900s)");
my $done_pat = qr/System restart required|Restart required|upgrade complete|closed by remote host|Connection to localhost closed/i;
my $result = $work_stream->wait_for($done_pat, 900);
if ($result) {
    say "  do-release-upgrade finished";
    log_output("do-release-upgrade stream", $result);
    die_msg("do-release-upgrade failed: No new release found (network issue?)")
        if $result =~ /No new release found/;
} else {
    log_output("do-release-upgrade stream at timeout", $work_stream->read_all());
    die_msg("do-release-upgrade did not complete within 900s");
}

my (undef, $rc) = vm_ssh('true');
if ($rc == 0) {
    step("Rebooting after do-release-upgrade");
    vm_ssh('sudo reboot');
}

# ── verify Questing ──────────────────────────────────────────────────────────

$console_stream->switch(log_phase("post-upgrade-console"));
step("Waiting for SSH after upgrade reboot");
wait_ssh(300);

step("Verifying upgraded system");
vm_status_like('os questing', 'cat /etc/os-release', "...\nVERSION_ID=\"25.10\"\n...");
my $kernel = vm_ssh_ok('uname -r');
chomp $kernel;
say "  Kernel: $kernel";
vm_status_like('secure boot', 'mokutil --sb-state', 'SecureBoot enabled');

step("Verifying GRUB was not reinstalled");
for my $pkg (qw(grub-common grub2-common grub-efi-amd64-signed grub-pc)) {
    vm_status_like("$pkg uninstalled",
        "dpkg-query -W -f '\${Status}' $pkg 2>/dev/null || echo 'not-installed'",
        '*not-installed');
}

vm_status_like('status post-upgrade', 'sudo gurb status', <<~'EXPECT',
    ...
    shim          [..] OK
    ...
    mm            [..] OK
    systemd-boot  [..] OK
    ...
    *-generic     [..] OK
    *-generic     [..] OK
    ...
    MOK: [..]enrolled
EXPECT
    'MISSING', 'GRUB');

vm_destroy();
done();
