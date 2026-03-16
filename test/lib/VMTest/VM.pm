package VMTest::VM;
# VM lifecycle management: create, start, stop, restart.
# State persisted in files (PID files, port file) and tmux sessions.
#
# Replaces run-vm.sh with Perl that supports QEMU restart + Secure Boot toggle.

use v5.40;
use Exporter 'import';
use File::Basename qw(dirname);
use File::Path qw(make_path);
use IO::Socket::UNIX;
use Time::HiRes ();

our @EXPORT = qw(vm_create vm_start vm_stop vm_restart vm_destroy);

# ── singleton state ──────────────────────────────────────────────────────────

my %S;

sub _init (%opts) {
    $S{script_dir}    = $opts{script_dir}    // die "script_dir required\n";
    $S{vm_dir}        = $opts{vm_dir}        // $S{script_dir};
    $S{project_dir}   = dirname($S{script_dir});
    $S{tmux_session}  = $opts{tmux_session}  // 'gurb-vm';
    $S{smp}           = $ENV{VM_SMP} // 6;
    $S{ram}           = $ENV{VM_RAM} // 3072;
    make_path($S{vm_dir}) unless -d $S{vm_dir};
}

sub _s ($key) { $S{$key} // die "VM not initialized (missing $key)\n" }
sub _path ($name) { "$S{vm_dir}/$name" }

# ── helpers ──────────────────────────────────────────────────────────────────

sub _run (@cmd) {
    system(@cmd) == 0 or die "command failed: @cmd\n";
}

sub _run_capture (@cmd) {
    open my $fh, '-|', @cmd or die "fork: $!";
    my $out = do { local $/; <$fh> } // '';
    close $fh;
    return ($out, $? >> 8);
}

sub _write_file ($path, $content) {
    open my $fh, '>', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub _read_file ($path) {
    open my $fh, '<', $path or return undef;
    chomp(my $val = <$fh>);
    close $fh;
    return $val;
}

sub _write_pid ($name, $pid) {
    _write_file("$S{vm_dir}/$name.pid", "$pid\n");
}

sub _read_pid ($name) {
    _read_file("$S{vm_dir}/$name.pid");
}

sub _pid_alive ($name) {
    my $pid = _read_pid($name) or return 0;
    return kill(0, $pid) ? $pid : 0;
}

sub _kill_pid ($name) {
    my $pid = _read_pid($name) or return;
    if (kill(0, $pid)) {
        kill('TERM', $pid);
        for (1..50) {
            last unless kill(0, $pid);
            Time::HiRes::sleep(0.1);
        }
        kill('KILL', $pid) if kill(0, $pid);
    }
    unlink "$S{vm_dir}/$name.pid";
}

sub _tmux (@args) {
    my ($out, $rc) = _run_capture('tmux', @args);
    return ($out, $rc);
}

sub _tmux_ok (@args) {
    my ($out, $rc) = _tmux(@args);
    die "tmux failed: tmux @args\n" if $rc;
    return $out;
}

# ── virtiofsd management ─────────────────────────────────────────────────────

sub _ensure_virtiofsd ($name, $sock, $shared_dir) {
    # If PID is alive and socket exists, reuse
    if (_pid_alive($name) && -S $sock) {
        say "  $name: reusing (pid " . _read_pid($name) . ")";
        return;
    }

    # Dead or missing — clean up and respawn
    _kill_pid($name);
    unlink $sock;

    STDOUT->flush();
    STDERR->flush();
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec 'virtiofsd', '--socket-path', $sock,
            '--shared-dir', $shared_dir, '--sandbox=none';
        die "exec virtiofsd: $!";
    }
    _write_pid($name, $pid);

    # Wait for socket
    for (1..20) {
        last if -S $sock;
        Time::HiRes::sleep(0.1);
    }
    -S $sock or die "virtiofsd socket $sock not created\n";
    say "  $name: started (pid $pid)";
}

# ── release map ──────────────────────────────────────────────────────────────

my %VERSION_MAP = (plucky => '25.04', questing => '25.10');

# ── vm_create ────────────────────────────────────────────────────────────────

sub vm_create (%opts) {
    _init(%opts) unless $S{script_dir};

    my $distro  = $opts{distro}  // 'plucky';
    my $version = $VERSION_MAP{$distro}
        // die "unknown release '$distro' (use: plucky or questing)\n";

    my $sd  = _s('script_dir');
    my $vd  = _s('vm_dir');
    my $pd  = _s('project_dir');

    # ── preflight ────────────────────────────────────────────────────────
    my $ovmf = $ENV{OVMF_FV} // die "OVMF_FV not set. Enter the nix devshell first.\n";
    for my $cmd (qw(qemu-system-x86_64 xorriso tmux virtiofsd)) {
        system("command -v $cmd >/dev/null 2>&1") == 0
            or die "$cmd not found\n";
    }

    # ── SSH key ──────────────────────────────────────────────────────────
    my $vm_key = "$sd/vm_key";
    unless (-f $vm_key) {
        _run('ssh-keygen', '-t', 'ed25519', '-f', $vm_key, '-N', '', '-C', 'gurb-test');
    }

    # ── user-data ────────────────────────────────────────────────────────
    open my $pub, '<', "$vm_key.pub" or die "read $vm_key.pub: $!";
    chomp(my $pubkey = <$pub>);
    close $pub;

    open my $tmpl, '<', "$sd/user-data.template" or die "read user-data.template: $!";
    my $ud = do { local $/; <$tmpl> };
    close $tmpl;
    $ud =~ s/\@SSH_PUBKEY\@/$pubkey/g;
    _write_file("$sd/user-data", $ud);

    # ── download base image (shared across parallel runs) ──────────────
    my $base = "$sd/ubuntu-${version}-minimal-cloudimg-amd64.img";
    $S{base_image} = $base;
    unless (-f $base) {
        my $url = "https://cloud-images.ubuntu.com/minimal/releases/${distro}/release/ubuntu-${version}-minimal-cloudimg-amd64.img";
        say "Downloading Ubuntu $distro minimal cloud image...";
        _run('curl', '-L', '-o', "$base.tmp", $url);
        rename "$base.tmp", $base or die "rename: $!";
    }

    # ── cloud-init seed ISO ──────────────────────────────────────────────
    my $seed = _path('seed.iso');
    say "Building cloud-init seed ISO...";
    _run('xorriso', '-as', 'mkisofs',
        '-volid', 'cidata', '-joliet', '-rock',
        '-o', $seed,
        "$sd/user-data", "$sd/meta-data");

    # ── qcow2 overlay ───────────────────────────────────────────────────
    my $overlay = _path('vm-overlay.qcow2');
    say "Creating qcow2 overlay (8G)...";
    unlink $overlay;
    _run('qemu-img', 'create', '-f', 'qcow2', '-b', $base, '-F', 'qcow2', $overlay, '8G');

    # ── OVMF vars ────────────────────────────────────────────────────────
    my $efivars = _path('efivars.fd');
    _run('install', '-m', '644', "$ovmf/OVMF_VARS.ms.fd", $efivars);
    unlink "$vd/vm_known_hosts";

    # ── apt-cache dir ────────────────────────────────────────────────────
    mkdir "$vd/apt-cache" unless -d "$vd/apt-cache";

    $S{distro}  = $distro;
    $S{version} = $version;
    say "VM created (Ubuntu $distro $version)";
}

# ── vm_start ─────────────────────────────────────────────────────────────────

sub vm_start (%opts) {
    _init(%opts) unless $S{script_dir};

    my $secure = $opts{secure} // 1;
    my $sd  = _s('script_dir');
    my $vd  = _s('vm_dir');
    my $pd  = _s('project_dir');
    my $ses = _s('tmux_session');
    my $ovmf = $ENV{OVMF_FV} // die "OVMF_FV not set\n";

    # Kill stale QEMU from a previous run (e.g. interrupted test)
    _kill_pid('vm') if _pid_alive('vm');

    # ── ensure virtiofsd ─────────────────────────────────────────────────
    my $sock_pkg = _path('virtiofs-pkg.sock');
    my $sock_apt = _path('virtiofs-apt.sock');

    _ensure_virtiofsd('virtiofsd-pkg', $sock_pkg, "$pd/pkg");
    _ensure_virtiofsd('virtiofsd-apt', $sock_apt, "$vd/apt-cache");

    # Clean stale QMP socket before launch
    my $qmp_sock = _path('qmp.sock');
    unlink $qmp_sock;

    # ── tmux session (kill stale, start fresh) ──────────────────────────
    my (undef, $has_session) = _tmux('has-session', '-t', $ses);
    _tmux('kill-session', '-t', $ses) if $has_session == 0;
    _tmux_ok('new-session', '-d', '-s', $ses);

    # ── build QEMU command ───────────────────────────────────────────────
    my $overlay = _path('vm-overlay.qcow2');
    my $efivars = _path('efivars.fd');
    my $seed    = _path('seed.iso');
    my $ram     = _s('ram');
    my $smp     = _s('smp');

    # SB ON:  real efivars (MOK enrolled, writable) + MS firmware + SMM protection
    # SB OFF: disposable copy with SecureBootEnable=false (PK/MOK/boot entries preserved)
    my ($ovmf_code, $run_efivars);
    if ($secure) {
        $ovmf_code   = "$ovmf/OVMF_CODE.ms.fd";
        $run_efivars = $efivars;
    } else {
        $ovmf_code   = "$ovmf/OVMF_CODE.ms.fd";
        $run_efivars = _path('efivars-nosb.fd');
        _run('virt-fw-vars', '-i', $efivars, '-o', $run_efivars,
             '--set-false', 'SecureBootEnable');
    }

    my @qemu = (
        'qemu-system-x86_64',
        '-machine', "q35,smm=on,accel=kvm,memory-backend=mem0",
        '-cpu', 'host',
        '-m', $ram,
        '-smp', $smp,
        '-nographic',
        '-object', "memory-backend-memfd,id=mem0,size=${ram}M,share=on",
    );

    # Secure Boot: SMM-protected pflash
    if ($secure) {
        push @qemu, '-global', 'driver=cfi.pflash01,property=secure,value=on';
    }

    push @qemu, (
        '-drive', "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code",
        '-drive', "if=pflash,format=raw,unit=1,file=$run_efivars",
        '-drive', "file=$overlay,if=virtio,format=qcow2,cache=unsafe",
        '-drive', "file=$seed,if=virtio,format=raw,readonly=on",
        '-chardev', "socket,id=vfs-pkg,path=$sock_pkg",
        '-device', 'vhost-user-fs-pci,chardev=vfs-pkg,tag=hostpkg',
        '-chardev', "socket,id=vfs-apt,path=$sock_apt",
        '-device', 'vhost-user-fs-pci,chardev=vfs-apt,tag=hostaptcache',
        '-nic', 'user,hostfwd=tcp::0-:22',
        '-qmp', "unix:$qmp_sock,server,nowait",
    );

    # Send QEMU command to tmux pane 0
    my $cmd_str = join(' ', map { /[\s"'\\]/ ? "'$_'" : $_ } @qemu);
    _tmux_ok('send-keys', '-t', "$ses:0", $cmd_str, 'Enter');

    # ── discover SSH port ────────────────────────────────────────────────
    # pane_pid is bash; QEMU is its child
    Time::HiRes::sleep(0.5);  # let QEMU start
    my $bash_pid = _tmux_ok('list-panes', '-t', "$ses:0", '-F', '#{pane_pid}');
    chomp $bash_pid;

    my $qemu_pid;
    for (1..40) {
        chomp($qemu_pid = `pgrep -P $bash_pid qemu-system 2>/dev/null`);
        last if $qemu_pid;
        Time::HiRes::sleep(0.25);
    }
    die "could not find QEMU child of bash (pid=$bash_pid)\n" unless $qemu_pid;
    _write_pid('vm', $qemu_pid);

    my $ssh_port;
    for (1..40) {
        my ($ss_out) = _run_capture('ss', '-tlnp', '( sport != :0 )');
        for my $line (split /\n/, $ss_out) {
            if ($line =~ /pid=\Q$qemu_pid\E,/ && $line =~ /:(\d+)\s/) {
                $ssh_port = $1;
                last;
            }
        }
        last if $ssh_port;
        Time::HiRes::sleep(0.25);
    }
    die "could not detect QEMU SSH port for pid $qemu_pid\n" unless $ssh_port;

    _write_file("$S{vm_dir}/vm_port", "$ssh_port\n");

    my $sb_str = $secure ? "Secure Boot ON" : "Secure Boot OFF";
    say "VM started ($sb_str, SSH port $ssh_port, QEMU pid $qemu_pid)";
}

# ── QMP graceful powerdown ────────────────────────────────────────────────────

sub _qmp_powerdown {
    my $sock_path = _path('qmp.sock');
    -S $sock_path or die "QMP socket not found\n";

    my $sock = IO::Socket::UNIX->new(
        Peer => $sock_path,
        Type => SOCK_STREAM,
    ) or die "connect QMP: $!\n";

    $sock->autoflush(1);

    # Read greeting
    my $greeting = <$sock>;
    die "no QMP greeting\n" unless $greeting;

    # Handshake
    print $sock qq({"execute":"qmp_capabilities"}\n);
    my $cap_reply = <$sock>;

    # ACPI power button
    print $sock qq({"execute":"system_powerdown"}\n);
    my $pd_reply = <$sock>;

    close $sock;
}

# ── vm_stop ──────────────────────────────────────────────────────────────────

sub vm_stop (%opts) {
    _init(%opts) unless $S{script_dir};
    my $ses = _s('tmux_session');

    my $pid = _read_pid('vm');

    # Try graceful ACPI shutdown via QMP
    if ($pid && kill(0, $pid)) {
        eval { _qmp_powerdown() };
        if ($@) {
            warn "QMP powerdown failed ($@), falling back to SIGTERM\n";
        } else {
            # Wait up to 15s for QEMU to exit
            for (1..150) {
                last unless kill(0, $pid);
                Time::HiRes::sleep(0.1);
            }
        }
    }

    # If still alive, fall back to SIGTERM → SIGKILL
    _kill_pid('vm') if $pid && kill(0, $pid);

    # Reset terminal in tmux pane (QEMU may have left it in raw mode)
    my (undef, $has) = _tmux('has-session', '-t', $ses);
    if ($has == 0) {
        _tmux('send-keys', '-t', "$ses:0", '', '');  # flush
        Time::HiRes::sleep(0.3);
        _tmux('send-keys', '-t', "$ses:0", 'reset', 'Enter');
        Time::HiRes::sleep(0.5);
    }

    unlink _path('qmp.sock');
    say "VM stopped";
}

# Full cleanup: kill everything including virtiofsd and tmux session.
sub vm_destroy (%opts) {
    _init(%opts) unless $S{script_dir};
    my $ses = _s('tmux_session');

    _kill_pid('vm');
    _kill_pid('virtiofsd-pkg');
    _kill_pid('virtiofsd-apt');
    unlink _path('virtiofs-pkg.sock');
    unlink _path('virtiofs-apt.sock');
    unlink _path('qmp.sock');

    my (undef, $has) = _tmux('has-session', '-t', $ses);
    _tmux('kill-session', '-t', $ses) if $has == 0;

    say "VM destroyed";
}

# ── vm_restart ───────────────────────────────────────────────────────────────

sub vm_restart (%opts) {
    _init(%opts) unless $S{script_dir};
    vm_stop();
    vm_start(%opts);
}

1;
