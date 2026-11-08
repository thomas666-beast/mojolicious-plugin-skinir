use strict;
use warnings;
use Test::More;
use File::Spec;
use FindBin;
use JSON::PP ();

my $dir = "$FindBin::Bin/../lib/Mojolicious/Plugin/Skinir/resources/lang";
opendir(my $dh, $dir) or die "cannot open $dir: $!";
my %lang;
for my $f (grep { /\.json\z/ } readdir $dh) {
  open my $fh, '<:encoding(UTF-8)', File::Spec->catfile($dir, $f) or die $!;
  local $/;
  (my $name = $f) =~ s/\.json\z//;
  $lang{$name} = JSON::PP->new->decode(<$fh>);   # already decoded text
}

ok $lang{en}, 'English file exists';
my @en = sort keys %{$lang{en}};
for my $l (grep { $_ ne 'en' } sort keys %lang) {
  my @missing = grep { !exists $lang{$l}{$_} } @en;
  my @extra   = grep { !exists $lang{en}{$_} } keys %{$lang{$l}};
  is_deeply \@missing, [], "$l has every English key";
  is_deeply \@extra,   [], "$l has no unknown keys";
  for my $k (@en) {
    next unless exists $lang{$l}{$k};
    my @a = sort($lang{en}{$k} =~ /\{(\w+)\}/g);
    my @b = sort($lang{$l}{$k}  =~ /\{(\w+)\}/g);
    is_deeply \@b, \@a, "$l.$k keeps the same {placeholders}" or diag "$k";
  }
}
done_testing;
