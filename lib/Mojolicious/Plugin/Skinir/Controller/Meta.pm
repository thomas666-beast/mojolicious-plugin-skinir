package Mojolicious::Plugin::Skinir::Controller::Meta;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub bootstrap ($c) {
  my $s    = $c->skinir;
  my $cfg  = $s->config;
  my $user = $s->user($c);

  my (%groups, @order);
  for my $res (@{$s->resources}) {
    my $class = $c->model($res->model);
    next unless $c->allowed('view_any', $class->new);
    my $g = $res->group;
    push @order, $g unless $groups{$g};
    push @{$groups{$g}}, {
      key   => $res->uri_key,
      label => $s->resource_label($c, $res),
      icon  => $res->icon,
    };
  }
  my @nav = map {
    +{group => $s->group_label($c, $_), items => [sort { lc $a->{label} cmp lc $b->{label} } @{$groups{$_}}]}
  } @order;

  my $cards = $c->_dashboard_cards;
  $c->render(json => {
    app => {name => $cfg->{name}, logo => $cfg->{logo}, base => $cfg->{path}, api => $s->api_url},
    user => {
      id    => $user->get_key,
      name  => $user->get_attribute($cfg->{name_field}) // $user->get_attribute($cfg->{login_field}),
      login => $user->get_attribute($cfg->{login_field}),
    },
    locale   => $c->locale,
    locales  => $cfg->{locales},
    messages => $s->messages($c),
    navigation => \@nav,
    per_page_options => $cfg->{per_page_options},
    dashboard => [map { $_->meta($c, 'dashboard') } @$cards],
  });
}

sub _dashboard_cards ($c) {
  my $cards = $c->skinir->config->{cards} // [];
  $cards = $cards->($c) if ref $cards eq 'CODE';
  return $cards;
}

sub set_locale ($c) {
  my $s = $c->skinir;
  my $l = $c->req->json->{locale} // '';
  return $c->render(json => {message => 'Unknown locale'}, status => 422)
    unless grep { $_ eq $l } @{$s->config->{locales}};
  $c->locale($l);
  $c->render(json => {ok => \1});
}

sub _metric_response ($c, $metrics, $scope) {
  my ($m) = grep { $_->key eq $c->stash('key') } @$metrics;
  return $c->render(json => {message => 'Unknown metric'}, status => 404) unless $m;
  my $res = eval { $m->calculate($c, scalar $c->param('range')) };
  if (my $e = $@) {
    return $c->render(json => {message => 'Range not allowed'}, status => 422) if $e =~ /not allowed/;
    $c->app->log->error("Skinir metric '" . $m->key . "' failed: $e");
    return $c->render(json => {message => 'Metric failed'}, status => 500);
  }
  $c->render(json => $res);
}

sub dashboard_metric ($c) { $c->_metric_response($c->_dashboard_cards, 'dashboard') }

sub resource_metric ($c) {
  my $s   = $c->skinir;
  my $res = $s->resource($c->stash('resource'))
    or return $c->render(json => {message => 'Unknown resource'}, status => 404);
  my $class = $c->model($res->model);
  return $c->render(json => {message => 'Forbidden'}, status => 403) unless $c->allowed('view_any', $class->new);
  $c->_metric_response($res->cards($c), $res->uri_key);
}

1;
