use strict;
use warnings;
use ExtUtils::MakeMaker;
use File::Find qw(find);

my %install;
find({no_chdir => 1, wanted => sub {
  return unless -f $_ && m{\A(lib/(?:.*\.pm|Mojolicious/Plugin/Skinir/resources/.+))\z};
  my $file = $1;
  (my $target = $file) =~ s{\Alib/}{\$(INST_LIB)/};
  $install{$file} = $target;
}}, 'lib');

WriteMakefile(
  NAME         => 'Mojolicious::Plugin::Skinir',
  VERSION_FROM => 'lib/Mojolicious/Plugin/Skinir.pm',
  ABSTRACT     => 'A Nova-style admin panel (Vue 3 + Tailwind) for Mojolicious',
  AUTHOR       => 'Skinir contributors',
  LICENSE      => 'artistic_2',
  MIN_PERL_VERSION => '5.020',
  PM => \%install,
  PREREQ_PM    => {
    'Mojolicious' => '9.0',
    'Mojolicious::Plugin::Yggdrasil'   => '0.04',
    'Yggdrasil'                      => '0.05',
    'Mojolicious::Plugin::FormRequest' => 0,
    'Crypt::Passphrase'              => 0,
    'Crypt::Passphrase::Argon2'      => 0,
    'Crypt::Passphrase::Bcrypt'      => 0,
    'Crypt::URandom'                 => 0,
    'Text::CSV'                      => '2.00',
    'Mojolicious::Plugin::Policy'      => 0,
    'Mojolicious::Plugin::Translatable' => 0,
  },
  TEST_REQUIRES => {'Test::More' => 0, 'DBD::SQLite' => '1.66'},
  META_MERGE   => {'meta-spec' => {version => 2}, resources => {}},
  test         => {TESTS => 't/*.t'},
);
