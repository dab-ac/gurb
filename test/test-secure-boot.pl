#!/usr/bin/env perl
# test/test-secure-boot.pl
#
# Tests: Secure Boot enforcement at each level of the trust chain:
#   A) shim → systemd-boot (bad-key bootloader rejected)
#   B) shim → UKI (bad-key UKI rejected)
#   C) kernel → module (unsigned .ko rejected by lockdown)
#
# Recovery: power-cycle with Secure Boot OFF, fix, power-cycle with SB ON.
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

# Purge GRUB so we're booting purely through shim → systemd-boot → UKI
step("Purging GRUB for clean test");
vm_ssh('sudo apt purge -y grub-common grub-efi-amd64-signed grub2-common grub-pc');
vm_ssh_ok('sudo rm -rf /boot/grub');

# ── setup: throwaway key + linux-headers ──────────────────────────────────

step("Creating throwaway signing key (not enrolled)");
vm_ssh_ok("openssl req -new -x509 -newkey rsa:2048 -keyout /var/tmp/bad.key -out /var/tmp/bad.pem -nodes -days 1 -subj '/CN=badkey'");

step("Installing linux-headers for module test");
my $kver = vm_ssh_ok('uname -r');
chomp $kver;
vm_ssh_ok("sudo apt install -y linux-headers-$kver make gcc");

# ── identify paths ────────────────────────────────────────────────────────

my $shim_dir = vm_ssh_ok("dirname \$(sudo gurb status 2>&1 | grep -oP '/efi/\\S+shimx64\\.efi')");
chomp $shim_dir;
$shim_dir ||= '/efi/EFI/systemd';
my $grub_path = "$shim_dir/grubx64.efi";
say "  systemd-boot: $grub_path";

my $uki_name = vm_ssh_ok("sudo ls /efi/EFI/Linux/ | grep '$kver'");
chomp $uki_name;
die_msg("No UKI found for $kver") unless $uki_name;
my $uki_path = "/efi/EFI/Linux/$uki_name";
say "  UKI: $uki_path";

# ══════════════════════════════════════════════════════════════════════════
# Test A: systemd-boot enforcement (shim rejects bad-key bootloader)
# ══════════════════════════════════════════════════════════════════════════

step("Test A: stripping + re-signing systemd-boot with bad key");
vm_ssh_ok("sudo sbattach --remove $grub_path || true");  # strip existing sigs
vm_ssh_ok("sudo sbsign --key /var/tmp/bad.key --cert /var/tmp/bad.pem --output $grub_path $grub_path");

step("Verifying systemd-boot signed with bad key");
vm_check("sudo sbverify --list $grub_path", 'signature');

step("Rebooting with bad-key systemd-boot");
$console_stream->switch(log_phase("sb-boot-reject-console"));
vm_ssh('sudo reboot');

step("Watching console for Secure Boot rejection (60s)");
my $reject_a = $console_stream->wait_for(
    qr/Access Denied|Security Policy Violation|Verification failed|Bad (Shim )?signature|Failed to execute/i,
    60
);
if ($reject_a) {
    say "  Secure Boot correctly rejected bad-key systemd-boot";
    log_output("rejection console (test A)", strip_ansi($reject_a));
} else {
    # No console message — SSH must also be unreachable
    my (undef, $ssh_rc) = run_capture(ssh_cmd($SCRIPT_DIR, state_dir => vm_dir(), connect_timeout => 10), 'true');
    die_msg("VM booted with bad-key systemd-boot — shim did not enforce!") if $ssh_rc == 0;
    say "  VM did not boot — shim enforcement confirmed";
}

step("Power-cycling with Secure Boot OFF to recover");
vm_restart(secure => 0);
$console_stream->switch(log_phase("sb-off-recovery-a"));
wait_ssh(180);

step("Re-signing with enrolled MOK key");
my ($resign_a_out, $resign_a_rc) = vm_ssh('sudo gurb resign all');
assert_contains('resign all exits cleanly (A)', ($resign_a_rc == 0 ? 'ok' : "rc=$resign_a_rc"), 'ok');

step("Power-cycling with Secure Boot ON");
$console_stream->switch(log_phase("sb-on-verify-a"));
vm_restart(secure => 1);
mok_continue_boot();
wait_ssh(180);

step("Verifying recovery (Test A)");
vm_status_like('secure boot on', 'mokutil --sb-state', 'SecureBoot enabled');
vm_status_like('status post-recovery-A', 'sudo gurb status', <<~'EXPECT', 'MISSING', 'UNSIGNED');
    ...
    systemd-boot  [..] SIGNED
    *-generic     [..] SIGNED
    ...
    MOK: enrolled
    ...
EXPECT

# ══════════════════════════════════════════════════════════════════════════
# Test B: UKI enforcement (shim rejects bad-key UKI)
# ══════════════════════════════════════════════════════════════════════════

step("Test B: stripping + re-signing UKI with bad key");
vm_ssh_ok("sudo sbattach --remove $uki_path || true");  # strip existing sigs
vm_ssh_ok("sudo sbsign --key /var/tmp/bad.key --cert /var/tmp/bad.pem --output $uki_path $uki_path");

step("Rebooting with bad-key UKI");
$console_stream->switch(log_phase("uki-reject-console"));
vm_ssh('sudo reboot');

step("Watching console for UKI rejection (60s)");
my $reject_b = $console_stream->wait_for(
    qr/Access Denied|Security Policy Violation|Verification failed|Bad (Shim )?signature|Failed to execute|Failed to load/i,
    60
);
if ($reject_b) {
    say "  Secure Boot correctly rejected bad-key UKI";
    log_output("rejection console (test B)", strip_ansi($reject_b));
} else {
    my (undef, $ssh_rc) = run_capture(ssh_cmd($SCRIPT_DIR, state_dir => vm_dir(), connect_timeout => 10), 'true');
    die_msg("VM booted with bad-key UKI — shim did not enforce!") if $ssh_rc == 0;
    say "  VM did not boot — UKI enforcement confirmed";
}

step("Power-cycling with Secure Boot OFF to recover");
vm_restart(secure => 0);
$console_stream->switch(log_phase("sb-off-recovery-b"));
wait_ssh(180);

step("Re-signing with enrolled MOK key");
my ($resign_b_out, $resign_b_rc) = vm_ssh('sudo gurb resign all');
assert_contains('resign all exits cleanly (B)', ($resign_b_rc == 0 ? 'ok' : "rc=$resign_b_rc"), 'ok');

step("Power-cycling with Secure Boot ON");
$console_stream->switch(log_phase("sb-on-verify-b"));
vm_restart(secure => 1);
mok_continue_boot();
wait_ssh(180);

step("Verifying recovery (Test B)");
vm_status_like('secure boot on', 'mokutil --sb-state', 'SecureBoot enabled');
vm_status_like('status post-recovery-B', 'sudo gurb status', <<~'EXPECT', 'MISSING', 'UNSIGNED');
    ...
    systemd-boot  [..] SIGNED
    *-generic     [..] SIGNED
    ...
    MOK: enrolled
    ...
EXPECT

# ══════════════════════════════════════════════════════════════════════════
# Test C: Kernel module enforcement (lockdown rejects unsigned .ko)
# ══════════════════════════════════════════════════════════════════════════

step("Test C: building unsigned kernel module");
vm_ssh_ok('mkdir -p /tmp/testmod');

# Pipe C source and Makefile to avoid heredoc-over-SSH quoting issues
open my $fh, '|-', ssh_cmd($SCRIPT_DIR, state_dir => vm_dir()), 'cat > /tmp/testmod/hello.c'
    or die_msg("pipe to ssh: $!");
print $fh <<~'C';
    #include <linux/module.h>
    MODULE_LICENSE("GPL");
    static int __init h_init(void) { pr_info("hello\n"); return 0; }
    static void __exit h_exit(void) { pr_info("bye\n"); }
    module_init(h_init);
    module_exit(h_exit);
    C
close $fh or die_msg("write hello.c via ssh failed (rc=$?)");

vm_ssh_ok('echo "obj-m := hello.o" > /tmp/testmod/Makefile');

vm_ssh_ok("make -C /lib/modules/$kver/build M=/tmp/testmod modules");

step("Attempting to load unsigned module (expecting rejection)");
my ($insmod_out, $insmod_rc) = vm_ssh("sudo insmod /tmp/testmod/hello.ko");
die_msg("unsigned module loaded under Secure Boot — lockdown not enforcing!") if $insmod_rc == 0;
say "  Kernel correctly rejected unsigned module (rc=$insmod_rc)";
log_output("insmod rejection", $insmod_out);

step("Signing module with MOK key");
my $sign_file = vm_ssh_ok("find /usr/src/linux-headers-$kver -name sign-file -type f");
chomp $sign_file;
die_msg("sign-file not found in linux-headers") unless $sign_file;
vm_ssh_ok("sudo $sign_file sha256 /var/lib/shim-signed/mok/MOK.priv /var/lib/shim-signed/mok/MOK.pem /tmp/testmod/hello.ko");

step("Loading signed module");
vm_ssh_ok("sudo insmod /tmp/testmod/hello.ko");
say "  Signed module loaded successfully";

step("Cleaning up module");
vm_ssh_ok("sudo rmmod hello");

vm_destroy();
done();
