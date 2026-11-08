use strict;
use warnings;
use Test::More;
use FindBin;

my $res = "$FindBin::Bin/../lib/Mojolicious/Plugin/Skinir/resources";
for my $f ("public/skinir/app.js", "public/skinir/skinir.css", "templates/skinir/shell.html.ep", "templates/skinir/login.html.ep") {
  ok -s "$res/$f", "$f exists and is not empty";
}

sub slurp { open my $fh, '<', $_[0] or die $!; local $/; <$fh> }
my $js  = slurp("$res/public/skinir/app.js");
my $css = slurp("$res/public/skinir/skinir.css");

like $js, qr/global\.Skinir\s*=\s*Skinir/, 'bundle exposes window.Skinir';
unlike $js, qr/\blocalStorage\.setItem\([^)]*(csrf|token)/i, 'csrf token is never persisted';
unlike $js, qr/\bv-html="(?!paths")/, 'v-html only used for the static icon table';
like $css, qr/--color-brand-600/, 'brand palette present';
like $css, qr/\.dark\\:bg-slate-900/, 'dark variants present';

my $shell = slurp("$res/templates/skinir/shell.html.ep");
like $shell, qr/Skinir\.boot\(\)/, 'shell boots the client';
like $shell, qr/name="csrf-token"/, 'shell carries the csrf token';

done_testing;
