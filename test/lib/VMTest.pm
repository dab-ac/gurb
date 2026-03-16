package VMTest;
# Test utilities for gurb integration tests.
#
# Pure functions (output_like, strip_ansi, strip_mok_ui) work standalone.
# Harness functions (vm_ssh, tmux, step, etc.) require init() first.

use v5.40;
use Exporter 'import';
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Time::HiRes ();
use Digest::SHA qw(sha256_hex);
use Linux::Inotify2;

our @EXPORT = qw(
    output_like strip_ansi strip_mok_ui ssh_cmd
    init log_init log_msg log_output log_phase step die_msg fail_count elapsed vm_dir
    assert_contains assert_not_contains assert_output_like
    run_capture run_ok done
    vm_ssh vm_ssh_ok vm_check vm_status_like wait_ssh ssh_cmd_str
    parse_efi_entries
    vm_restart
    tmux tmux_ok tmux_capture tmux_send tmux_wait_stable
    mok_enroll mok_continue_boot
    tmux_session tmux_console tmux_work
);

# ── state ────────────────────────────────────────────────────────────────────

my %S = (
    step_num   => 0,
    fail_count => 0,
    t0         => 0,
    log_seq    => 0,
);

sub _test_name () { File::Basename::basename($0, '.pl') }

sub init (%opts) {
    my $name          = _test_name();
    $S{ssh_dir}       = $opts{ssh_dir}       // die "ssh_dir required\n";
    my $default_vm_dir = $ENV{VM_DIR} ? "$ENV{VM_DIR}/$name" : "$S{ssh_dir}/run/$name";
    $S{vm_dir}        = $opts{vm_dir}        // $default_vm_dir;
    $S{log_dir}       = $opts{log_dir}       // "$S{vm_dir}/logs";
    $S{tmux_session}  = $opts{tmux_session}  // "gurb-$name";
    $S{tmux_console}  = "$S{tmux_session}:0";
    $S{tmux_work}     = "$S{tmux_session}:work";
    $S{step_num}      = 0;
    $S{fail_count}    = 0;
    $S{t0}            = Time::HiRes::time();
    $S{log_seq}       = 0;
}

sub fail_count ()    { $S{fail_count} }
sub elapsed ()       { sprintf "%.1fs", Time::HiRes::time() - $S{t0} }
sub vm_dir ()       { $S{vm_dir} }
sub tmux_session () { $S{tmux_session} }
sub tmux_console () { $S{tmux_console} }
sub tmux_work ()    { $S{tmux_work} }

# ── pure functions ───────────────────────────────────────────────────────────

sub strip_ansi ($text) {
    $text =~ s/\e\[[0-9;]*[A-Za-z]//g;   # CSI sequences
    $text =~ s/\e\][^\a]*\a//g;           # OSC sequences
    $text =~ s/\e[()][0-9A-Z]//g;         # character set selection
    $text =~ s/\e[>=]//g;                 # keypad/application mode
    $text =~ s/\r\n/\n/g;                 # normalize CRLF to LF
    $text =~ s/\r/\n/g;                   # bare CR (progress lines) to LF
    $text =~ s/\n{3,}/\n\n/g;             # collapse excessive blank lines
    return $text;
}

sub strip_mok_ui ($text) {
    $text =~ s/[\x{2500}-\x{257F}\x{2580}-\x{259F}\x{25CF}\x{25C6}]/ /g;
    $text =~ s/[ \t]+/ /g;
    $text =~ s/^ //gm;
    $text =~ s/ $//gm;
    return $text;
}

# Fuzzy snapshot matching: compare output against a template with wildcards.
#
# Template syntax:
#   [..]  inside a line  = match any characters (like .*)
#   * at start of line   = match any prefix
#   ... alone on a line  = gap marker (skip zero or more output lines)
#
# Without a gap marker, template lines must match consecutive output lines.
# Without a leading ..., matching starts at the first output line.
# Without a trailing ..., no output lines may follow the last match.
#
# Optional reject patterns (separate list) are plain substrings checked
# against ALL output lines — if any line contains a reject string, the
# check fails.
#
# Returns: { ok => 1 }
#      or: { ok => 0, error => "...", detail => "..." }
#
sub output_like ($output, $template, @reject) {
    my @out_lines = grep { /\S/ } map { _normalize($_) } split /\n/, $output;

    # Parse template into segments separated by ... gap markers
    my (@segments, @current);
    my $leading_gap  = 0;
    my $trailing_gap = 0;

    for my $line (split /\n/, $template) {
        my $norm = _normalize($line);
        next if $norm eq '';
        if ($norm eq '...') {
            push @segments, [@current] if @current;
            @current = ();
            $leading_gap = 1 if !@segments;
            $trailing_gap = 1;
        } else {
            $trailing_gap = 0;
            push @current, $norm;
        }
    }
    push @segments, [@current] if @current;

    # Match segments against output
    my $oi = 0;
    for my $si (0 .. $#segments) {
        my @seg = @{$segments[$si]};
        my $can_skip = ($si == 0 && $leading_gap) || $si > 0;
        my $max_start = $can_skip ? @out_lines - @seg : $oi;

        my $found = 0;
        for my $start ($oi .. $max_start) {
            my $ok = 1;
            for my $pi (0 .. $#seg) {
                my $idx = $start + $pi;
                if ($idx >= @out_lines || $out_lines[$idx] !~ _pat_to_re($seg[$pi])) {
                    $ok = 0;
                    last;
                }
            }
            if ($ok) {
                $oi = $start + @seg;
                $found = 1;
                last;
            }
        }
        unless ($found) {
            return {
                ok    => 0,
                error => "pattern not found: $seg[0]",
                detail => join("\n", map { "  $_" } @out_lines),
            };
        }
    }

    # Unmatched trailing output
    if (!$trailing_gap && $oi < @out_lines) {
        return {
            ok    => 0,
            error => "unexpected output: $out_lines[$oi]",
            detail => join("\n", map { "  $_" } @out_lines[$oi .. $#out_lines]),
        };
    }

    # Reject: substring check against all output lines
    for my $rpat (@reject) {
        for my $line (@out_lines) {
            if (index($line, $rpat) >= 0) {
                return {
                    ok     => 0,
                    error  => "rejected: $line",
                    detail => "  contains: $rpat",
                };
            }
        }
    }

    return { ok => 1 };
}

sub _normalize ($s) { $s =~ s/[ \t]+/ /gr =~ s/^ //r =~ s/ $//r }

sub _pat_to_re ($pat) {
    my $re = quotemeta($pat);
    $re =~ s/\\\[\\\.\\\.\\]/.*/g;   # [..] → .*
    $re =~ s/^\\\*/.*/;              # leading * → .*
    return qr/^${re}$/;
}

# ── logging ──────────────────────────────────────────────────────────────────

sub _elapsed { sprintf "%.1fs", Time::HiRes::time() - $S{t0} }

sub log_init () {
    make_path($S{log_dir});
    unlink glob "$S{log_dir}/*.log";
    open $S{log_fh}, '>', "$S{log_dir}/00-test.log"
        or die "cannot open log: $!";
    $S{log_fh}->autoflush(1);
    say {$S{log_fh}} "[" . _elapsed() . "] Test started: $0";
}

sub log_msg {
    print {$S{log_fh}} "[" . _elapsed() . "] @_\n" if $S{log_fh};
}

sub log_output ($label, $text) {
    return unless $S{log_fh};
    my $fh = $S{log_fh};
    say $fh "--- $label ---";
    print $fh $text;
    say $fh "" unless $text =~ /\n$/;
    say $fh "--- end $label ---";
}

sub log_phase ($name) {
    $S{log_seq}++;
    sprintf "%s/%02d-%s.log", $S{log_dir}, $S{log_seq}, $name;
}

sub step ($msg) {
    $S{step_num}++;
    my $line = sprintf "==> [%d] [%s] %s", $S{step_num}, _elapsed(), $msg;
    say $line;
    log_msg($line);
}

sub die_msg ($msg) {
    log_msg("FATAL: $msg");
    my $pane = tmux_capture($S{tmux_console});
    log_output("console pane dump at failure", $pane);
    say STDERR "--- tmux console pane dump ---";
    say STDERR $pane;
    say STDERR "--- end dump ---";
    say STDERR "FATAL: $msg";
    say STDERR "Logs: $S{log_dir}/";
    exit 99;
}

# ── assertions ───────────────────────────────────────────────────────────────

sub _pass ($label) {
    say "  OK: $label";
    log_msg("  OK: $label");
}

sub _fail ($label, $msg) {
    say "  FAIL: $label — $msg";
    log_msg("  FAIL: $label — $msg");
    $S{fail_count}++;
}

sub assert_contains ($label, $output, $expected) {
    if (index($output, $expected) >= 0) {
        _pass($label);
        return 1;
    }
    _fail($label, "expected '$expected'");
    log_output("actual output", $output);
    return 0;
}

sub assert_not_contains ($label, $output, $unexpected) {
    if (index($output, $unexpected) >= 0) {
        _fail($label, "unexpected '$unexpected'");
        log_output("actual output", $output);
        return 0;
    }
    _pass($label);
    return 1;
}

sub assert_output_like ($label, $output, $template, @reject) {
    my $r = output_like($output, $template, @reject);
    if ($r->{ok}) {
        _pass($label);
        return 1;
    }
    say "  FAIL: $label — $r->{error}";
    say $r->{detail} if $r->{detail};
    log_msg("FAIL: $label — $r->{error}");
    log_output("actual output", $output);
    $S{fail_count}++;
    return 0;
}

# ── command execution ────────────────────────────────────────────────────────

sub run_capture (@cmd) {
    log_msg("run: @cmd");
    my $pid = open my $fh, '-|';
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDERR, '>&', \*STDOUT;
        exec @cmd or die "exec @cmd: $!\n";
    }
    my $out = do { local $/; <$fh> } // '';
    close $fh;
    my $rc = $? >> 8;
    log_output("stdout+stderr (rc=$rc)", $out);
    return ($out, $rc);
}

sub run_ok (@cmd) {
    my ($out, $rc) = run_capture(@cmd);
    die_msg("command failed (rc=$rc): @cmd") if $rc != 0;
    return $out;
}

# Print summary and exit.  Call at end of test.
sub done () {
    say "";
    say "=" x 44;
    say $S{fail_count} == 0 ? "ALL CHECKS PASSED" : "FAILURES: $S{fail_count}";
    say "=" x 44;
    say "Logs: $S{log_dir}/";
    exit($S{fail_count} > 0 ? 1 : 0);
}

# ── VM lifecycle (delegates to VMTest::VM) ────────────────────────────────────

sub vm_restart (%opts) {
    require VMTest::VM;
    VMTest::VM::vm_restart(%opts);
}

# ── SSH helpers ──────────────────────────────────────────────────────────────

# Build ssh argument list.  Works standalone (no init required).
# $dir is used for vm_key, vm_port, vm_known_hosts.
# Override state_dir to read vm_port/vm_known_hosts from a different path.
sub ssh_cmd ($dir, %opts) {
    my $state_dir = delete $opts{state_dir} // $dir;
    open my $f, '<', "$state_dir/vm_port" or die "cannot read $state_dir/vm_port: $!";
    chomp(my $port = <$f>);
    return (
        'ssh',
        '-i', "$dir/vm_key",
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=$state_dir/vm_known_hosts",
        '-o', "ConnectTimeout=" . ($opts{connect_timeout} // 10),
        '-p', $port,
        'ubuntu@localhost',
    );
}

sub _ssh_args (%opts) { ssh_cmd($S{ssh_dir}, state_dir => $S{vm_dir}, %opts) }

# SSH command as a shell string, for tmux_send.  Adds -t for TTY allocation.
sub ssh_cmd_str (@args) {
    my @cmd = (_ssh_args(), '-t', @args);
    join ' ', map { /[\s"'\\]/ ? "'$_'" : $_ } @cmd;
}

# Parse efibootmgr output into a list of { num => "000B", name => "...", path => "..." }.
# Returns entries in order of appearance (last = most recently created).
sub parse_efi_entries ($text) {
    my @entries;
    for my $line (split /\n/, $text) {
        if ($line =~ /^Boot([0-9A-Fa-f]{4})\*?\s+(.+?)\t+(.*)/) {
            push @entries, { num => $1, name => $2, path => $3 };
        }
    }
    return @entries;
}

sub vm_ssh (@args)      { run_capture(_ssh_args(), @args) }
sub vm_ssh_ok (@args)   { my ($o, $r) = vm_ssh(@args); die_msg("vm-ssh failed (rc=$r): @args") if $r; $o }

# Run SSH command and assert output contains (or doesn't contain) substrings.
# Prefix with ! for negative: vm_check('cmd', 'want', '!unwanted')
sub vm_check ($cmd, @expects) {
    my $out = vm_ssh_ok($cmd);
    for my $raw (@expects) {
        if ($raw =~ /^!(.+)/) {
            assert_not_contains("no $1", $out, $1);
        } else {
            assert_contains($raw, $out, $raw);
        }
    }
    return $out;
}

# Run SSH command and match output against a fuzzy snapshot template.
sub vm_status_like ($label, $cmd, $template, @reject) {
    my ($out, $rc) = vm_ssh($cmd);
    die_msg("SSH transport failed (rc=$rc): $cmd") if $rc == 255;
    assert_output_like($label, $out, $template, @reject);
    return $out;
}

# Poll SSH with short connect timeout until it comes up.
sub wait_ssh ($timeout = 180) {
    log_msg("waiting for SSH (timeout=${timeout}s)");
    my $deadline = Time::HiRes::time() + $timeout;
    my @cmd = (_ssh_args(connect_timeout => 2), 'true');
    # Give the guest time to begin shutting down before checking
    Time::HiRes::sleep(3);
    for (1..20) {
        last if system("@cmd >/dev/null 2>&1") != 0;
        Time::HiRes::sleep(0.5);
    }
    while (Time::HiRes::time() < $deadline) {
        my $rc = system("@cmd >/dev/null 2>&1");
        return log_msg("SSH is up") if $rc == 0;
    }
    die_msg("SSH not available after ${timeout}s");
}

# ── tmux helpers ─────────────────────────────────────────────────────────────

sub tmux (@args) { run_capture('tmux', @args) }

sub tmux_ok (@args) {
    my ($out, $rc) = tmux(@args);
    die_msg("tmux failed: tmux @args") if $rc != 0;
    return $out;
}

sub tmux_capture ($target) {
    my ($out) = tmux('capture-pane', '-t', $target, '-p');
    return $out;
}

sub tmux_send ($target, @keys) {
    tmux_ok('send-keys', '-t', $target, @keys);
}

# Wait for tmux pane screen to stabilize (capture-pane snapshot, for TUI).
sub tmux_wait_stable ($target, $stable_secs = 2, $timeout_secs = 120) {
    log_msg("tmux_wait_stable($target, ${stable_secs}s, ${timeout_secs}s)");
    my $deadline = Time::HiRes::time() + $timeout_secs;
    my $prev_hash = '';
    my $stable_since = Time::HiRes::time();

    while (Time::HiRes::time() < $deadline) {
        my $pane = tmux_capture($target);
        my $hash = sha256_hex($pane);
        if ($hash eq $prev_hash) {
            return $pane if Time::HiRes::time() - $stable_since >= $stable_secs;
        } else {
            $stable_since = Time::HiRes::time();
            $prev_hash = $hash;
        }
        Time::HiRes::sleep(0.1);
    }
    my $pane = tmux_capture($target);
    log_output("pane at timeout", $pane);
    die_msg("timeout waiting for $target to stabilize (${timeout_secs}s)");
}

# Capture tmux pane with ANSI escape sequences (for detecting selection highlight).
sub tmux_capture_ansi ($target) {
    my ($out) = tmux('capture-pane', '-e', '-t', $target, '-p');
    return $out;
}

# Parse MokManager/UEFI TUI structure from a captured pane.
# Returns: { title => "...", items => ["item1", "item2", ...] }
#
# The TUI is a box drawn with Unicode box chars. Each row has:
#   │ menu item text │
# On narrow terminals the box wraps, so we join everything, split on the
# vertical-bar box char (U+2502 │), and extract the text segments.
sub _mok_parse_screen ($pane) {
    utf8::decode($pane) unless utf8::is_utf8($pane);
    my $flat = $pane =~ s/\n/ /gr;

    # Split on │ (U+2502) — the vertical box-drawing char that frames each item
    my @segments = split /\x{2502}/, $flat;

    # Strip remaining box-drawing chars and whitespace from each segment
    my @items;
    my $title = '';
    for my $seg (@segments) {
        $seg =~ s/[\x{2500}-\x{257F}\x{2580}-\x{259F}\x{25CF}\x{25C6}]//g;
        $seg =~ s/^\s+|\s+$//g;
        $seg =~ s/\s+/ /g;
        next if $seg eq '';
        next if $seg =~ /\[ OK \]/;
        next if $seg =~ /ubuntu|ttyS|login/i;
        next unless $seg =~ /[a-zA-Z]/;
        push @items, $seg;
    }
    return { title => $title, items => \@items };
}

# Detect which item index is selected by looking for ANSI highlight.
# Uses the same │-split approach as _mok_parse_screen so wrapping is handled
# correctly: joining all lines reassembles items split across terminal rows.
sub _mok_selected_index ($ansi_pane) {
    utf8::decode($ansi_pane) unless utf8::is_utf8($ansi_pane);
    my $flat = $ansi_pane =~ s/\n/ /gr;
    my @segments = split /\x{2502}/, $flat;
    my $item_idx = -1;
    for my $seg (@segments) {
        my $has_highlight = ($seg =~ /\e\[40m/);
        # Strip ANSI + box-drawing to check if this is a menu item
        (my $clean = $seg) =~ s/\e\[[0-9;]*m//g;
        $clean =~ s/[\x{2500}-\x{257F}\x{2580}-\x{259F}\x{25CF}\x{25C6}]//g;
        $clean =~ s/^\s+|\s+$//g;
        $clean =~ s/\s+/ /g;
        next if $clean eq '';
        next if $clean =~ /\[ OK \]/;
        next if $clean =~ /ubuntu|ttyS|login/i;
        next unless $clean =~ /[a-zA-Z]/;
        $item_idx++;
        return $item_idx if $has_highlight;
    }
    return undef;
}

# Navigate MokManager TUI to select a menu item by name.
# Captures the screen, finds the item, navigates to it, verifies selection,
# then presses Enter. Dies if the target is not found or selection fails.
sub mok_select ($target, %opts) {
    my $timeout = $opts{timeout} // 30;
    my $settle  = $opts{settle}  // 2;

    my $pane = tmux_wait_stable($S{tmux_console}, $settle, $timeout);
    my $screen = _mok_parse_screen($pane);
    my @items = @{$screen->{items}};

    log_output("MokManager screen", strip_mok_ui($pane));
    say "  MokManager: title='$screen->{title}'" if $screen->{title};
    say "  MokManager: items=[" . join(', ', map { "'$_'" } @items) . "]";

    # Find target item position.
    # Build a flexible regex: allow optional whitespace between words and at
    # word boundaries where terminal line wrapping may split the TUI box.
    my $pattern = join '\s+', map { join '\s?', map { quotemeta } split // }
                              split /\s+/, $target;
    my $idx;
    for my $i (0 .. $#items) {
        if ($items[$i] =~ /$pattern/i) {
            $idx = $i;
            last;
        }
    }
    die_msg("MokManager: '$target' not found. Items: " . join(', ', @items))
        unless defined $idx;

    # Navigate: first item is selected by default
    if ($idx > 0) {
        tmux_send($S{tmux_console}, ('Down') x $idx);
        Time::HiRes::sleep(0.5);
    }

    # Verify selection by index (handles line-wrapped items correctly)
    my $ansi = tmux_capture_ansi($S{tmux_console});
    my $sel_idx = _mok_selected_index($ansi);
    if (defined $sel_idx && $sel_idx != $idx) {
        log_output("MokManager ANSI (wrong selection)", $ansi);
        die_msg("MokManager: expected item $idx ('$target') selected, but item $sel_idx is highlighted");
    }

    tmux_send($S{tmux_console}, 'Enter');
    say "  MokManager: selected '$items[$idx]'";
    sleep 1;
    return $pane;
}

# Send raw text to the MokManager TUI (e.g. password entry).
sub mok_type ($text) {
    tmux_send($S{tmux_console}, $text, 'Enter');
    my $pane = tmux_wait_stable($S{tmux_console}, 1, 15);
    log_output("MokManager after input", strip_mok_ui($pane));
    return $pane;
}

# ── MokManager flows ────────────────────────────────────────────────────────

# Complete MOK enrollment flow: reboot → catch "press any key" → navigate
# MokManager → enter password → wait for reboot → wait for SSH.
# Expects: MOK enrollment already queued via `mokutil --import`.
sub mok_enroll ($console_stream, $password) {
    step("Rebooting for MokManager enrollment");
    tmux_ok('resize-window', '-t', $S{tmux_session}, '-x', '80', '-y', '25');
    $console_stream->switch(log_phase("mokmanager-console"));
    vm_ssh('sudo reboot');

    step("Catching MokManager 'Press any key'");
    $console_stream->wait_for(qr/press any key/i, 60)
        or die_msg("MokManager 'Press any key' not seen");
    tmux_send($S{tmux_console}, 'Up');

    step("Navigating MokManager");
    tmux_wait_stable($S{tmux_console}, 2, 30);
    mok_select("Enroll MOK");
    mok_select("Continue");
    mok_select("Yes");

    step("Entering MokManager password");
    my $pane = mok_type($password);
    my $flat = strip_mok_ui($pane) =~ s/\s+//gr;
    die_msg("'Reboot' not visible after MokManager password") unless $flat =~ /reboot/i;
    tmux_send($S{tmux_console}, 'Enter');

    step("Waiting for SSH after MokManager reboot");
    wait_ssh(180);
}

# Dismiss MokManager "Continue boot" flow that appears after SB state changes.
# MokManager may show: OK dialog → menu with "Continue boot" → boots.
# Logs every screen unconditionally.
sub mok_continue_boot (%opts) {
    my $timeout = $opts{timeout} // 30;
    my $depth   = $opts{_depth}  // 0;
    my $pane = tmux_wait_stable($S{tmux_console}, 3, $timeout);
    my $screen = _mok_parse_screen($pane);
    log_output("post-restart screen", strip_mok_ui($pane));

    # If we see MokManager menu items, navigate to "Continue boot"
    my @items = @{$screen->{items}};
    if (grep { /Continue boot/i } @items) {
        mok_select("Continue boot");
    } elsif ($depth < 3 && @items <= 4 && grep { /\bOK\b/ } @items) {
        # Bare OK dialog (few items = likely a real dialog, not a GRUB screen)
        mok_select("OK");
        mok_continue_boot(timeout => $timeout, _depth => $depth + 1);
    }
    # else: no dialog, boot is proceeding normally
}

# ── PaneStream: streaming tmux pane output via pipe-pane ─────────────────────

{
    package PaneStream;

    sub _touch ($path) { open my $fh, '>>', $path or die "touch $path: $!"; close $fh }

    sub _setup_inotify ($self) {
        my $in = Linux::Inotify2->new or die "inotify: $!";
        $in->watch($self->{logfile}, Linux::Inotify2::IN_MODIFY())
            or die "inotify watch $self->{logfile}: $!";
        $self->{inotify} = $in;
    }

    sub new ($class, $target, $logfile) {
        unlink $logfile;
        _touch($logfile);
        my $self = bless {
            target  => $target,
            logfile => $logfile,
            pos     => 0,
        }, $class;
        $self->_setup_inotify();
        system('tmux', 'pipe-pane', '-t', $target, "cat >> $logfile") == 0
            or die "tmux pipe-pane failed for $target\n";
        return $self;
    }

    sub read_new ($self) {
        open my $fh, '<:raw', $self->{logfile} or return '';
        seek $fh, $self->{pos}, 0;
        my $new = do { local $/; <$fh> } // '';
        $self->{pos} = tell $fh;
        close $fh;
        return $new;
    }

    sub read_all ($self) {
        open my $fh, '<:raw', $self->{logfile} or return '';
        my $all = do { local $/; <$fh> } // '';
        $self->{pos} = tell $fh;
        close $fh;
        return $all;
    }

    sub mark ($self) {
        $self->{pos} = -s $self->{logfile} // 0;
    }

    sub switch ($self, $new_logfile) {
        system('tmux', 'pipe-pane', '-t', $self->{target});  # stop old
        unlink $new_logfile;
        _touch($new_logfile);
        $self->{logfile} = $new_logfile;
        $self->{pos} = 0;
        $self->_setup_inotify();
        system('tmux', 'pipe-pane', '-t', $self->{target}, "cat >> $new_logfile") == 0
            or die "tmux pipe-pane failed for $self->{target}\n";
    }

    sub _inotify_wait ($self, $secs) {
        my $fd = $self->{inotify}->fileno;
        vec(my $rin = '', $fd, 1) = 1;
        select($rin, undef, undef, $secs);
    }

    # Wait for regex in new output, blocking on inotify between checks.
    sub wait_for ($self, $pattern, $timeout = 60) {
        my $deadline = Time::HiRes::time() + $timeout;
        my $buf = '';
        while (Time::HiRes::time() < $deadline) {
            $buf .= VMTest::strip_ansi($self->read_new());
            return $buf if $buf =~ $pattern;
            my $remaining = $deadline - Time::HiRes::time();
            last if $remaining <= 0;
            $self->_inotify_wait($remaining);
        }
        return undef;
    }

    # Wait for output to stop flowing, blocking on inotify between checks.
    sub wait_stable ($self, $stable_secs = 2, $timeout = 120) {
        my $deadline = Time::HiRes::time() + $timeout;
        my $last_change = Time::HiRes::time();
        my $prev_size = -s $self->{logfile} // 0;

        while (Time::HiRes::time() < $deadline) {
            my $size = -s $self->{logfile} // 0;
            if ($size != $prev_size) {
                $last_change = Time::HiRes::time();
                $prev_size = $size;
            } elsif (Time::HiRes::time() - $last_change >= $stable_secs) {
                return $self->read_new();
            }
            $self->_inotify_wait($stable_secs);
        }
        return undef;
    }

    sub stop ($self) {
        system('tmux', 'pipe-pane', '-t', $self->{target});
    }

    sub DESTROY ($self) { $self->stop() }
}

1;
