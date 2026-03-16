package VMTest::Setup;
# Common VM setup: boot → install gurb → MOK enrollment → verify.
# Extracted from test-grub-purge-upgrade.pl so all test scripts share it.

use v5.40;
use Exporter 'import';
use VMTest;
use VMTest::VM;

our @EXPORT = qw(setup_gurb vm_destroy);

# Boot VM, install gurb, enroll MOK, verify everything works.
# Returns: { console_stream => PaneStream, work_stream => PaneStream, boot_num => $hex }
sub setup_gurb (%opts) {
    my $script_dir = $opts{script_dir} // die "script_dir required\n";
    my $distro     = $opts{distro}     // 'plucky';

    # ── boot ──────────────────────────────────────────────────────────────

    step("Creating and launching $distro VM");
    vm_create(
        script_dir    => $script_dir,
        vm_dir        => VMTest::vm_dir(),
        tmux_session  => VMTest::tmux_session(),
        distro        => $distro,
    );
    vm_start();
    my $cs = PaneStream->new(VMTest::tmux_console(), log_phase("boot-console"));

    step("Waiting for SSH");
    wait_ssh(180);

    step("Verifying base system");
    vm_status_like('secure boot', 'mokutil --sb-state', 'SecureBoot enabled');

    # ── install ───────────────────────────────────────────────────────────

    $cs->switch(log_phase("install-console"));

    step("Installing gurb");
    vm_ssh_ok('sudo mount -t virtiofs hostpkg /mnt');
    vm_ssh_ok('dpkg-deb -b /mnt /tmp/gurb.deb');
    vm_ssh_ok('sudo apt-get update -qq && sudo apt install -y /tmp/gurb.deb');

    step("Verifying gurb installed");
    vm_status_like('status post-install', 'sudo gurb status', <<~'EXPECT');
        ...
        shim [..] SIGNED
        ...
        Key/cert not found [..]
        ...
    EXPECT

    # ── generate MOK ──────────────────────────────────────────────────────

    step("Generating MOK key (interactive via tmux)");
    tmux_ok('new-window', '-t', VMTest::tmux_session(), '-n', 'work');
    my $ws = PaneStream->new(VMTest::tmux_work(), log_phase("mok-generate"));

    tmux_send(VMTest::tmux_work(), ssh_cmd_str('sudo gurb generate'), 'Enter');
    $ws->wait_for(qr/input password/i, 30)
        // die_msg("never saw mokutil password prompt");
    tmux_send(VMTest::tmux_work(), 'gurbgurb', 'Enter');
    $ws->wait_for(qr/input password again/i, 15)
        // die_msg("never saw second password prompt");
    tmux_send(VMTest::tmux_work(), 'gurbgurb', 'Enter');
    $ws->wait_stable(2, 30);

    step("Verifying MOK is pending");
    vm_status_like('status post-generate', 'sudo gurb status', <<~'EXPECT');
        ...
        shim [..] SIGNED
        ...
        Key: [..]
        ...
        MOK: pending
        ...
    EXPECT

    # ── cmdline ───────────────────────────────────────────────────────────

    step("Setting cmdline with serial console");
    vm_ssh_ok("echo 'cmdline_extra = console=ttyS0,115200' | sudo tee /etc/gurb/config");

    $ws->switch(log_phase("cmdline"));
    tmux_send(VMTest::tmux_work(), ssh_cmd_str('sudo gurb cmdline'), 'Enter');
    $ws->wait_for(qr/\[y\/N\]/, 30)
        // die_msg("never saw cmdline confirmation prompt");
    tmux_send(VMTest::tmux_work(), 'y', 'Enter');
    $ws->wait_stable(2, 15);

    # ── sign + boot entry ─────────────────────────────────────────────────

    step("Signing all kernels (--force, MOK not yet enrolled)");
    vm_ssh_ok('sudo gurb resign --force all');

    step("Creating boot entry");
    my ($out) = vm_ssh('sudo gurb bootentry');
    my @entries = parse_efi_entries($out);
    my ($entry) = grep { $_->{name} =~ /shimmed systemd-boot/ } reverse @entries;
    die_msg("Could not find 'shimmed systemd-boot' in bootentry output") unless $entry;
    my $boot_num = $entry->{num};
    say "  Boot entry: $boot_num";

    step("Setting boot order");
    vm_ssh_ok("sudo efibootmgr --bootorder $boot_num");

    # ── MokManager enrollment ─────────────────────────────────────────────

    mok_enroll($cs, 'gurbgurb');

    # ── verify ────────────────────────────────────────────────────────────

    $cs->switch(log_phase("post-mok-console"));

    step("Verifying boot after MOK enrollment");
    vm_status_like('cmdline', 'cat /proc/cmdline', '[..] console=ttyS0,115200 [..]');
    vm_status_like('secure boot', 'mokutil --sb-state', 'SecureBoot enabled');
    vm_status_like('status post-MOK', 'sudo gurb status', <<~'EXPECT', 'MISSING');
        ...
        shim          [..] SIGNED
        ...
        systemd-boot  [..] SIGNED
        *-generic     [..] SIGNED
        ...
        MOK: enrolled
        ...
    EXPECT

    return {
        console_stream => $cs,
        work_stream    => $ws,
        boot_num       => $boot_num,
    };
}

1;
