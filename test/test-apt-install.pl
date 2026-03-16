#!/usr/bin/env perl
# test/test-apt-install.pl
#
# Smoke test: install gurb from https://apt.dab.ac using the exact
# instructions from the landing page, on a system that already has
# Ubuntu's DKMS MOK (from update-secureboot-policy).
#
# Not in the CI matrix — requires a published release and internet.
#
# Prerequisites: nix devshell, a published .deb at apt.dab.ac
use v5.40;
use FindBin;
use File::Basename qw(dirname);
use lib "$FindBin::Bin/lib";
use VMTest;
use VMTest::VM;

my $SCRIPT_DIR  = $FindBin::Bin;
my $PROJECT_DIR = dirname($SCRIPT_DIR);

VMTest::init(ssh_dir => $SCRIPT_DIR);

chdir $PROJECT_DIR or die "chdir $PROJECT_DIR: $!";
log_init();

# ── boot ─────────────────────────────────────────────────────────────────────

step("Creating and launching VM");
vm_create(
    script_dir   => $SCRIPT_DIR,
    vm_dir       => VMTest::vm_dir(),
    tmux_session => VMTest::tmux_session(),
);
vm_start();

step("Waiting for SSH");
wait_ssh(180);

step("Verifying base system");
vm_status_like('secure boot', 'mokutil --sb-state', 'SecureBoot enabled');

# ── create pre-existing DKMS MOK (as update-secureboot-policy would) ─────────

step("Creating pre-existing DKMS MOK via update-secureboot-policy");
vm_ssh_ok('sudo apt-get update -qq');
vm_ssh_ok('sudo apt install -y shim-signed');
# update-secureboot-policy --new-key generates a DKMS-only MOK with modsign OID
# at /var/lib/shim-signed/mok/MOK.priv (same path gurb uses)
vm_ssh_ok('sudo update-secureboot-policy --new-key');

step("Verifying DKMS MOK exists");
vm_check('sudo test -f /var/lib/shim-signed/mok/MOK.priv && echo KEY_EXISTS', 'KEY_EXISTS');
vm_check('sudo test -f /var/lib/shim-signed/mok/MOK.der && echo DER_EXISTS', 'DER_EXISTS');
# The DKMS MOK has modsign OID — unsuitable for EFI binary signing
my $eku = vm_ssh_ok('sudo openssl x509 -in /var/lib/shim-signed/mok/MOK.der -inform DER -noout -ext extendedKeyUsage 2>&1');
say "  DKMS MOK EKU: $eku";

# ── install from apt.dab.ac (landing page instructions) ──────────────────────

step("Adding repo key and source (as documented on apt.dab.ac)");
vm_ssh_ok('curl -fsSL https://apt.dab.ac/dab.ac.gpg | sudo tee /usr/share/keyrings/dab.ac.gpg > /dev/null');
vm_ssh_ok(q{echo 'Types: deb
URIs: https://apt.dab.ac
Suites: ./
Signed-By: /usr/share/keyrings/dab.ac.gpg' | sudo tee /etc/apt/sources.list.d/dab.ac.sources > /dev/null});

step("apt update + install gurb");
vm_ssh_ok("sudo apt-get update -qq");
vm_ssh_ok("sudo apt install -y gurb");

# ── verify ───────────────────────────────────────────────────────────────────

step("Verifying gurb installed from repo");
vm_check('which gurb', '/usr/bin/gurb');
vm_check('dpkg -s gurb | grep Status', 'install ok installed');

step("Verifying gurb status shows existing key (DKMS MOK)");
my ($status_out, $status_rc) = vm_ssh('sudo gurb status');
say $status_out;

# gurb status should show the existing key and warn about modsign OID
vm_status_like('shim present', 'sudo gurb status', <<~'EXPECT');
    ...
    shim [..] OK
    ...
EXPECT

# The DKMS MOK has modsign OID — gurb generate should show it and offer overwrite
step("Running gurb generate (should show existing DKMS key and offer overwrite)");
my $cs = PaneStream->new(VMTest::tmux_console(), log_phase("generate-console"));
tmux_ok('new-window', '-t', VMTest::tmux_session(), '-n', 'work');
my $ws = PaneStream->new(VMTest::tmux_work(), log_phase("generate"));
tmux_send(VMTest::tmux_work(), ssh_cmd_str('sudo gurb generate'), 'Enter');
my $gen_out = $ws->wait_for(qr/Overwrite\?/i, 30);
die_msg("never saw overwrite prompt — gurb should detect existing DKMS key") unless $gen_out;
assert_contains('shows existing key', $gen_out, 'Key:');
say "  gurb generate detected existing key and prompted to overwrite";

# Don't actually overwrite — just verify detection works
tmux_send(VMTest::tmux_work(), 'n', 'Enter');
$ws->wait_stable(2, 10);

vm_destroy();
done();
