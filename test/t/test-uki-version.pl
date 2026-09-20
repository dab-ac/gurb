#!/usr/bin/env perl
use v5.40;
use FindBin;
use File::Temp qw(tempdir);
use Test::More;

sub read_file ($path) {
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}
sub write_file ($path, $text) {
    open my $fh, '>', $path or die "$path: $!";
    print $fh $text;
    close $fh or die "$path: $!";
}

my $source = read_file("$FindBin::Bin/../../pkg/etc/kernel/install.d/60-ukify.install");
for my $version ('7.0.0-15-generic', '7.0.0-31-generic') {
    my $tmp = tempdir(CLEANUP => 1);
    mkdir "$tmp/conf";
    mkdir "$tmp/stage";
    my $config = "[UKI]\nSecureBootPrivateKey=/test/key\nSecureBootCertificate=/test/cert\n";
    write_file("$tmp/conf/uki.conf", $config);
    write_file("$tmp/conf/cmdline", "root=/dev/test quiet\n");
    write_file("$tmp/conf/devicetree", "board.dtb\n");
    write_file("$tmp/conf/board.dtb", "test device tree\n");
    write_file("$tmp/os-release", "ID=ubuntu\nVERSION=26.04\nIMAGE_VERSION=old\n");
    write_file("$tmp/builder", <<~'SH');
        #!/bin/sh
        set -eu
        cp "$KERNEL_INSTALL_CONF_ROOT/uki.conf" "$OUTPUT/config"
        cp "$KERNEL_INSTALL_CONF_ROOT/gurb-os-release" "$OUTPUT/osrel"
        cmp "$KERNEL_INSTALL_CONF_ROOT/cmdline" "$ORIGINAL/cmdline"
        cmp "$KERNEL_INSTALL_CONF_ROOT/board.dtb" "$ORIGINAL/board.dtb"
        exit "${FAIL:-0}"
        SH
    chmod 0755, "$tmp/builder";
    my $hook = $source;
    $hook =~ s{/usr/lib/kernel/install.d/60-ukify.install}{$tmp/builder};
    $hook =~ s{osrel=/etc/os-release}{osrel=$tmp/os-release};
    write_file("$tmp/hook", $hook);
    local %ENV = (%ENV,
        KERNEL_INSTALL_LAYOUT => 'uki', KERNEL_INSTALL_UKI_GENERATOR => 'ukify',
        KERNEL_INSTALL_STAGING_AREA => "$tmp/stage", KERNEL_INSTALL_CONF_ROOT => "$tmp/conf",
        OUTPUT => $tmp, ORIGINAL => "$tmp/conf");
    for my $fail (0, 42) {
        $ENV{FAIL} = $fail;
        system('sh', "$tmp/hook", 'add', $version, '/entry', '/kernel');
        is($? >> 8, $fail, "$version: builder exit propagated");
        is_deeply([glob "$tmp/stage/*"], [], 'temporary configuration removed');
        is(read_file("$tmp/conf/uki.conf"), $config, 'original configuration unchanged');
        like(read_file("$tmp/config"), qr/\Q$config\E/, 'signing settings preserved');
        like(read_file("$tmp/config"), qr/OSRelease=\@/, 'metadata passed to ukify');
        my $osrel = read_file("$tmp/osrel");
        like($osrel, qr/^IMAGE_VERSION="\Q$version\E"$/m, 'kernel version embedded');
        is(scalar(() = $osrel =~ /^IMAGE_VERSION=/mg), 1, 'old image version replaced');
        like($osrel, qr/^ID=ubuntu$/m, 'OS identity preserved');
    }
}

for my $pair (
    ['26.04 LTS (Resolute Raccoon)', '26.04.1 LTS (Resolute Raccoon)'],
    ['7.0.0-31-generic', '7.0.0-15-generic'],
) {
    is(system('systemd-analyze', 'compare-versions', $pair->[0], '>', $pair->[1]),
       0, "$pair->[0] sorts above $pair->[1]");
}
done_testing();
