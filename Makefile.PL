use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
  NAME         => 'Mojolicious::Plugin::Skinir',
  VERSION_FROM => 'lib/Mojolicious/Plugin/Skinir.pm',
  ABSTRACT     => 'A Nova-style admin panel (Vue 3 + Tailwind) for Mojolicious',
  AUTHOR       => 'Skinir contributors',
  LICENSE      => 'artistic_2',
  MIN_PERL_VERSION => '5.020',
  PREREQ_PM    => {
    'Mojolicious' => '9.0',
    'Mojolicious::Plugin::Yggdrasil'   => 0,
    'Mojolicious::Plugin::FormRequest' => 0,
    'Mojolicious::Plugin::Heimdall'    => 0,
    'Mojolicious::Plugin::Policy'      => 0,
    'Mojolicious::Plugin::Translatable' => 0,
  },
  TEST_REQUIRES => {'Test::More' => 0},
  META_MERGE   => {'meta-spec' => {version => 2}, resources => {}},
  test         => {TESTS => 't/*.t'},
);
