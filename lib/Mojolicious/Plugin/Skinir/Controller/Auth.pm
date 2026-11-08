package Mojolicious::Plugin::Skinir::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub _render_login ($c, %extra) {
  my $s = $c->skinir;
  if (my $l = $c->param('lang')) { $c->locale($l) if grep { $_ eq $l } @{$s->config->{locales}} }
  $c->render(
    template => 'skinir/login',
    format   => 'html',
    name     => $s->config->{name},
    logo     => $s->config->{logo},
    locale   => $c->locale,
    locales  => $s->config->{locales},
    login_url => $s->url('login'),
    login_field => $s->config->{login_field},
    css_url  => '/skinir/skinir.css?v=' . $Mojolicious::Plugin::Skinir::VERSION,
    tt       => sub ($k) { $s->t($c, $k) },
    error    => undef,
    old      => '',
    %extra,
  );
}

sub form ($c) {
  my $s = $c->skinir;
  my $u = $s->user($c);
  return $c->redirect_to($s->url) if $u && $s->may_enter($c, $u);
  $c->_render_login;
}

sub login ($c) {
  my $s = $c->skinir;
  my $v = $c->validation;
  return $c->_render_login(error => $s->t($c, 'login_csrf'), status => 400)
    if $v->csrf_protect->has_error('csrf_token');

  my $id = $c->param('identifier') // '';
  if ($s->throttled($c)) {
    return $c->_render_login(error => $s->t($c, 'login_throttled'), old => $id, status => 429);
  }
  if ($s->attempt($c, $id, $c->param('password'))) {
    my $to = delete $c->session->{skinir_return_to};
    my $base = $s->config->{path};
    # only ever redirect inside the panel (no open redirects)
    $to = $s->url unless defined $to && $to =~ m{\A\Q$base\E(?:/[^/\\][^\\]*)?\z} && $to !~ m{/skinir-api|/login};
    return $c->redirect_to($to);
  }
  $c->_render_login(error => $s->t($c, 'login_failed'), old => $id, status => 422);
}

sub logout ($c) {
  $c->skinir->logout($c);
  $c->render(json => {ok => \1, redirect => $c->skinir->url('login')});
}

1;
