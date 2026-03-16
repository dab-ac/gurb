#!/usr/bin/env perl
# Unit tests for VMTest::output_like
use v5.40;
use FindBin;
use lib "$FindBin::Bin/../lib";
use VMTest qw(output_like);

my $tests = 0;
my $fails = 0;

sub ok ($name, $got, $want_ok, $want_err = undef) {
    $tests++;
    if ($got->{ok} != $want_ok) {
        say "FAIL: $name — got ok=$got->{ok}, want $want_ok";
        say "  error: $got->{error}" if $got->{error};
        $fails++;
        return;
    }
    if ($want_err && (!$got->{error} || index($got->{error}, $want_err) < 0)) {
        say "FAIL: $name — error '$got->{error}' doesn't contain '$want_err'";
        $fails++;
        return;
    }
    say "ok: $name";
}

my $OUT = "aaa 111\nbbb 222\nccc 333\nddd 444\n";

# ── wildcards ────────────────────────────────────────────────────────────────
ok("[..] mid",         output_like("a xxx b\n", "a [..] b"), 1);
ok("[..] prefix",      output_like("aaa 111\n", "[..] 111"), 1);
ok("[..] suffix",      output_like("aaa 111\n", "aaa [..]"), 1);
ok("[..] no match",    output_like("aaa 111\n", "aaa [..] 333"), 0);
ok("* prefix",         output_like("bbb 222\n", "*222"), 1);

# ── strict consecutive (no ...) ──────────────────────────────────────────────
ok("exact full",       output_like($OUT, "aaa 111\nbbb 222\nccc 333\nddd 444"), 1);
ok("missing line",     output_like("a\nc\n", "a\nb\nc"), 0, "not found");
ok("extra line",       output_like("a\nX\nb\n", "a\nb"), 0, "not found");
ok("swapped",          output_like("b\na\n", "a\nb"), 0, "not found");
ok("wrong line",       output_like("a\nX\nc\n", "a\nb\nc"), 0, "not found");
ok("two diffs apart",  output_like("a\nX\nc\nY\ne\n", "a\nb\nc\nd\ne"), 0, "not found");
ok("trailing extra",   output_like("a\nb\nc\n", "a\nb"), 0, "unexpected");
ok("leading extra",    output_like("X\na\nb\n", "a\nb"), 0, "not found");

# ── gap markers (...) ───────────────────────────────────────────────────────
ok("leading gap",      output_like("X\na\n", "...\na"), 1);
ok("trailing gap",     output_like("a\nX\n", "a\n..."), 1);
ok("middle gap",       output_like("a\nX\nY\nb\n", "a\n...\nb"), 1);
ok("gap skips zero",   output_like("a\nb\n", "a\n...\nb"), 1);
ok("surrounded",       output_like("X\na\nY\n", "...\na\n..."), 1);
ok("all gaps",         output_like("X\na\nY\nb\nZ\n", "...\na\n...\nb\n..."), 1);
ok("gap between segs", output_like($OUT, "aaa 111\n...\nddd 444"), 1);
ok("no gap = strict",  output_like($OUT, "aaa 111\nddd 444"), 0, "not found");

# ── duplicate lines ──────────────────────────────────────────────────────────
ok("need two have two", output_like("a\na\n", "a\na"), 1);
ok("need two have one", output_like("a\nb\n", "a\na"), 0, "not found");

# ── reject ───────────────────────────────────────────────────────────────────
ok("reject absent",    output_like("a\n", "a", 'z'), 1);
ok("reject present",   output_like("a\n", "a", 'a'), 0, "rejected");
ok("reject substring", output_like("foobar\n", "...\nfoobar\n...", 'oba'), 0, "rejected");

# ── edge cases ───────────────────────────────────────────────────────────────
ok("empty both",       output_like("", ""), 1);
ok("empty output",     output_like("", "a"), 0);
ok("empty template",   output_like("a\n", ""), 0, "unexpected");
ok("only gaps",        output_like("a\n", "..."), 1);
ok("whitespace norm",  output_like("  a   b  \n", "a b"), 1);
ok("blanks skipped",   output_like("a\n\n\nb\n", "a\nb"), 1);

say "";
say "=" x 40;
say "$tests tests, $fails failures";
say "=" x 40;
exit($fails > 0 ? 1 : 0);
