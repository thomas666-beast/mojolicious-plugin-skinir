package Mojolicious::Plugin::Skinir;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(decode_json);
use Mojo::Loader qw(find_modules load_class);
use Mojo::Util qw(secure_compare);

our $VERSION = '0.01';

my $VUE_CDN = 'https://cdn.jsdelivr.net/npm/vue@3.5.13/dist/vue.global.prod.js';

has [qw(app config resources auth user_class _lang _by_key)];

# ---------------------------------------------------------------------------------
sub register ($self, $app, $conf) {
  my %cfg = (
    path             => '/admin',
    name             => 'Skinir',
    logo             => undef,
    locales          => [qw(en fr)],
    default_locale   => 'en',
    user_model       => 'User',
    login_field      => 'email',
    password_field   => 'password',
    name_field       => 'name',
    session_key      => 'skinir_uid',
    session_expires  => 8 * 3600,
    login_attempts   => 5,
    login_window     => 900,
    per_page_options => [10, 25, 50, 100],
    vue              => $VUE_CDN,           # URL, or 'local' => /skinir/vendor/vue.global.prod.js
    scripts          => [],
    styles           => [],
    uploads_dir      => undef,
    uploads_url      => '/uploads',
    gate             => undef,              # sub ($c, $user) -> bool
    cards            => undef,              # dashboard metrics: arrayref | sub ($c)
    policies         => {},
    resources        => undef,
    namespace        => undef,
    %{$app->config->{skinir} // {}},
    %{$conf // {}},
  );
  $cfg{path} =~ s{/+\z}{};
  $cfg{path} = '/' . $cfg{path} if length $cfg{path} && $cfg{path} !~ m{\A/};

  $self->app($app)->config(\%cfg);
  $self->{attempts} = {};

  die "Mojolicious::Plugin::Skinir: load the Yggdrasil plugin first (it provides the models).\n"
    unless _has_helper($app, 'model');

  $self->_load_dependencies($app, \%cfg);
  $self->_load_lang;
  $self->user_class(Yggdrasil->instance->model($cfg{user_model}));
  $self->_setup_auth($app, \%cfg);
  $self->_discover_resources($app, \%cfg);
  $self->_register_policies($app, \%cfg);

  # static assets + templates shipped inside the distribution
  my $res_dir = path(__FILE__)->sibling('Skinir', 'resources');
  push @{$app->static->paths},   $res_dir->child('public')->to_string;
  push @{$app->renderer->paths}, $res_dir->child('templates')->to_string;

  $cfg{uploads_dir} //= $app->home->child('public', 'uploads')->to_string;

  $app->helper(skinir      => sub ($c) { $self });
  $app->helper(skinir_user => sub ($c) { $self->user($c) });
  # Policies written for Mojolicious::Plugin::Policy expect $c->current_user.
  $app->helper(current_user => sub ($c) { $self->user($c) }) unless _has_helper($app, 'current_user');

  $self->_routes($app, \%cfg);
  return $self;
}

# ---- helpers ----------------------------------------------------------------------
sub _has_helper ($app, $name) { exists $app->renderer->helpers->{$name} ? 1 : 0 }

sub _load_dependencies ($self, $app, $cfg) {
  require Mojolicious::Plugin::FormRequest::Base;
  require Yggdrasil;

  $app->plugin(Translatable => {default => $cfg->{default_locale}}) unless _has_helper($app, 'trans');
  $app->plugin(FormRequest => {}) unless _has_helper($app, 'form_request');
  $app->plugin('Heimdall') unless _has_helper($app, 'heimdall');

  # unique:/exists: rules query the same database as the models
  $app->config->{FormRequest}{db} //= sub ($c) { $c->db($c->stash('skinir.connection'))->dbh };
}

sub _load_lang ($self) {
  my $dir = path(__FILE__)->sibling('Skinir', 'resources', 'lang');
  my %lang;
  for my $f ($dir->list->each) {
    next unless $f->basename =~ /\A([A-Za-z-]+)\.json\z/;
    $lang{$1} = decode_json($f->slurp);
  }
  $self->_lang(\%lang);
}

sub _setup_auth ($self, $app, $cfg) {
  require Mojolicious::Plugin::Heimdall::Auth;
  my $class = $self->user_class;
  $self->auth(
    Mojolicious::Plugin::Heimdall::Auth->new(
      session_key => $cfg->{session_key},
      load_user   => sub ($app, $id) { $class->find($id) },
    )
  );
}

sub _discover_resources ($self, $app, $cfg) {
  my @classes;
  if ($cfg->{resources}) { @classes = @{$cfg->{resources}} }
  else {
    my $base = ref $app;
    $base = 'main' if $base eq 'Mojolicious::Lite';
    @classes = sort { $a cmp $b } find_modules($cfg->{namespace} // "${base}::Resource");
  }
  my (@list, %by);
  for my $class (@classes) {
    if (my $e = load_class($class)) { die ref $e ? $e : "Skinir: resource class '$class' not found\n" }
    next unless $class->isa('Mojolicious::Plugin::Skinir::Resource');
    my $res = $class->new;
    my $key = $res->uri_key;
    die "Skinir: duplicate resource key '$key'\n" if $by{$key};
    $by{$key} = $res;
    push @list, $res;
  }
  $self->resources(\@list);
  $self->_by_key(\%by);
}

sub _register_policies ($self, $app, $cfg) {
  my %map = %{$cfg->{policies}};
  my $ygg = Yggdrasil->instance;
  for my $res (@{$self->resources}) {
    my $name = $ygg->model($res->model);
    $name =~ s/\A.*:://;                       # Mojolicious::Plugin::Policy keys by last segment
    $map{$name} //= $res->policy // 'Mojolicious::Plugin::Skinir::Policy';
  }
  for my $class (values %map) {
    if (my $e = load_class($class)) { die ref $e ? $e : "Skinir: policy class '$class' not found\n" }
  }
  if (_has_helper($app, 'allowed')) {
    $app->log->debug('Skinir: Policy plugin already loaded; make sure it knows the policies of your resources');
  }
  else { $app->plugin(Policy => {policies => \%map}) }
}

# ---- public API ----------------------------------------------------------------------
sub resource ($self, $ref) {
  return undef unless defined $ref;
  return $self->_by_key->{$ref} if $self->_by_key->{$ref};
  for my $r (@{$self->resources}) { return $r if ref $r eq $ref || $r->model eq $ref }
  return undef;
}

sub url ($self, @parts) { join '/', $self->config->{path}, @parts }
sub api_url ($self, @parts) { $self->url('skinir-api', @parts) }

sub user ($self, $c) {
  my $st = $c->stash;
  return $st->{'skinir.user'} if exists $st->{'skinir.user'};
  my $u = eval { $self->auth->current_user($c) };
  $u = undef unless ref $u;
  return $st->{'skinir.user'} = $u;
}

sub may_enter ($self, $c, $user) {
  my $gate = $self->config->{gate} or return 1;
  return $gate->($c, $user) ? 1 : 0;
}

# ---- authentication -------------------------------------------------------------------
sub throttled ($self, $c) {
  my $rec = $self->{attempts}{$c->tx->remote_address // '?'} or return 0;
  my $cfg = $self->config;
  if (time - $rec->[1] > $cfg->{login_window}) { delete $self->{attempts}{$c->tx->remote_address // '?'}; return 0 }
  return $rec->[0] >= $cfg->{login_attempts} ? 1 : 0;
}

sub _failed ($self, $c) {
  my $ip  = $c->tx->remote_address // '?';
  my $rec = $self->{attempts}{$ip} //= [0, time];
  $rec->[0]++;
  # keep the table from growing without bound
  if (keys %{$self->{attempts}} > 5000) { $self->{attempts} = {$ip => $rec} }
}

sub attempt ($self, $c, $identifier, $password) {
  my $cfg   = $self->config;
  my $pw    = $c->heimdall->password;
  my $class = $self->user_class;
  my $user  = (defined $identifier && length $identifier && defined $password)
    ? $class->query->where($cfg->{login_field}, $identifier)->first : undef;

  # always hash-verify so unknown accounts take as long as wrong passwords
  my $hash = $user ? $user->get_attribute($cfg->{password_field}) : undef;
  $hash = ($self->{dummy} //= $pw->hash('skinir-dummy-password')) unless defined $hash && length $hash;
  my $ok = eval { $pw->verify($password // '', $hash) } ? 1 : 0;

  if ($user && $ok && $self->may_enter($c, $user)) {
    delete $self->{attempts}{$c->tx->remote_address // '?'};
    $self->auth->login($c, $user->get_key);
    $c->session(expiration => $cfg->{session_expires});
    $c->stash('skinir.user' => $user);
    return $user;
  }
  $self->_failed($c);
  return undef;
}

sub logout ($self, $c) { $self->auth->logout($c); delete $c->stash->{'skinir.user'}; }

sub csrf_ok ($self, $c) {
  my $sent = $c->req->headers->header('X-CSRF-Token') // '';
  return length $sent && secure_compare($sent, $c->csrf_token) ? 1 : 0;
}

# ---- i18n -----------------------------------------------------------------------------
sub tr_or ($self, $c, $key, $default) {
  my $full = "skinir.$key";
  my $v = $c->trans($full);
  return $v eq $full ? $default : $v;
}

sub _builtin ($self, $locale, $key) {
  my $l = $self->_lang;
  return $l->{$locale}{$key} // $l->{en}{$key};
}

sub t ($self, $c, $key, %p) {
  my $v = $self->tr_or($c, $key, $self->_builtin($c->locale, $key) // $key);
  $v =~ s/\{(\w+)\}/exists $p{$1} ? $p{$1} : "{$1}"/ge;
  return $v;
}

sub messages ($self, $c) {
  my $loc = $c->locale;
  my %m;
  for my $k (keys %{$self->_lang->{en}}) {
    $m{$k} = $self->tr_or($c, $k, $self->_builtin($loc, $k));
  }
  return \%m;
}

sub field_label ($self, $c, $res, $field) {
  return $self->tr_or($c, 'fields.' . $res->uri_key . '.' . $field->attribute, $field->label);
}
sub resource_label ($self, $c, $res) {
  return $self->tr_or($c, 'resources.' . $res->uri_key . '.label', $res->label);
}
sub resource_singular ($self, $c, $res) {
  return $self->tr_or($c, 'resources.' . $res->uri_key . '.singular', $res->singular_label);
}
sub group_label ($self, $c, $group) {
  (my $k = lc $group) =~ s/[^a-z0-9]+/_/g;
  return $self->tr_or($c, "groups.$k", $group);
}

# ---- uploads --------------------------------------------------------------------------
sub upload_path ($self, $rel) { path($self->config->{uploads_dir}, split m{/}, $rel) }
sub upload_url  ($self, $rel) { join '/', $self->config->{uploads_url}, $rel }

sub delete_upload ($self, $rel) {
  return unless defined $rel && $rel =~ m{\Askinir/[A-Za-z0-9_-]+/[a-f0-9]{40}\.[a-z0-9]+\z};
  my $f = $self->upload_path($rel);
  unlink "$f" if -f "$f";
  return;
}

# ---- routes ---------------------------------------------------------------------------
sub _routes ($self, $app, $cfg) {
  my $ns   = 'Mojolicious::Plugin::Skinir::Controller';
  my $base = $app->routes->any($cfg->{path} || '/')->to(namespace => $ns);

  $base->get('/login')->to('auth#form')->name('skinir_login');
  $base->post('/login')->to('auth#login')->name('skinir_login_post');

  my $api = $base->under('/skinir-api' => sub ($c) { $self->_guard_api($c) });
  $api->get('/bootstrap')->to('meta#bootstrap');
  $api->post('/locale')->to('meta#set_locale');
  $api->post('/logout')->to('auth#logout');
  $api->get('/metrics/dashboard/:key')->to('meta#dashboard_metric');
  $api->get('/metrics/resources/:resource/:key')->to('meta#resource_metric');

  my $r = $api->any('/resources/:resource');
  $r->get('/')->to('resources#index');
  $r->post('/')->to('resources#store');
  $r->get('/creation-fields')->to('resources#creation_fields');
  $r->post('/bulk')->to('resources#bulk');
  $r->post('/actions/:action_key')->to('resources#run_action');
  $r->get('/options/:attribute')->to('resources#options');
  $r->get('/:id')->to('resources#show');
  $r->put('/:id')->to('resources#update');
  $r->delete('/:id')->to('resources#destroy');
  $r->get('/:id/update-fields')->to('resources#update_fields');
  $r->post('/:id/restore')->to('resources#restore');
  $r->delete('/:id/force')->to('resources#force_delete');

  $api->any('/*unknown' => sub ($c) { $c->render(json => {message => 'Not found'}, status => 404) });

  my $page = $base->under('/' => sub ($c) { $self->_guard_page($c) });
  $page->get('/')->to('shell#index')->name('skinir');
  $page->get('/*spa')->to('shell#index');
}

sub _guard_page ($self, $c) {
  my $u = $self->user($c);
  return 1 if $u && $self->may_enter($c, $u);
  $c->session(skinir_return_to => $c->req->url->path->to_string) if $c->req->method eq 'GET';
  $c->redirect_to($self->url('login'));
  return undef;
}

sub _guard_api ($self, $c) {
  my $u = $self->user($c);
  unless ($u) { $c->render(json => {message => 'Unauthenticated'}, status => 401); return undef }
  unless ($self->may_enter($c, $u)) { $c->render(json => {message => 'Forbidden'}, status => 403); return undef }
  my $m = $c->req->method;
  if ($m ne 'GET' && $m ne 'HEAD' && !$self->csrf_ok($c)) {
    $c->render(json => {message => 'Invalid CSRF token'}, status => 419);
    return undef;
  }
  return 1;
}

1;

__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Skinir - a Nova-style admin panel (Vue 3 + Tailwind) for Mojolicious

=head1 SYNOPSIS

  $self->plugin(Yggdrasil => {...});
  $self->plugin(Skinir => {
    path      => '/admin',
    name      => 'My Panel',
    namespace => 'MyApp::Resource',
  });

=head1 DESCRIPTION

Skinir builds a complete admin panel from resource classes. It composes
Yggdrasil (models, any of SQLite / PostgreSQL / MariaDB), FormRequest
(validation), Policy (authorization), Heimdall (sessions, password hashing)
and Translatable (i18n). See the distribution README.

=cut
