package Mojolicious::Plugin::Skinir::Controller::Shell;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::JSON qw(encode_json);

sub index ($c) {
  my $s   = $c->skinir;
  my $cfg = $s->config;
  my $vue = $cfg->{vue};
  $vue = '/skinir/vendor/vue.global.prod.js' if $vue eq 'local';

  my $json = encode_json({
    base   => $cfg->{path},
    api    => $s->api_url,
    csrf   => $c->csrf_token,
    name   => $cfg->{name},
    logo   => $cfg->{logo},
    locale => $c->locale,
  });
  $json =~ s/</\\u003c/g;                    # safe inside <script>

  $c->res->headers->cache_control('no-store');
  $c->render(
    template => 'skinir/shell',
    format   => 'html',
    name     => $cfg->{name},
    locale   => $c->locale,
    config   => $json,
    v        => $Mojolicious::Plugin::Skinir::VERSION,
    vue      => $vue,
    scripts  => $cfg->{scripts},
    styles   => $cfg->{styles},
  );
}

1;
