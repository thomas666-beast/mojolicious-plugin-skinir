package Mojolicious::Plugin::Skinir;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(decode_json);
use Mojo::Loader qw(find_modules load_class);
use Mojo::Util qw(secure_compare);

our $VERSION = '0.03';

my $VUE_CDN = 'https://cdn.jsdelivr.net/npm/vue@3.5.13/dist/vue.global.prod.js';

has [qw(app config resources user_class _lang _by_key)];

# ---------------------------------------------------------------------------------
sub register ($self, $app, $conf) {
  my %cfg = (
    path             => '/admin',
    name             => 'Skinir',
    logo             => undef,
    locales          => [qw(en fr)],
    default_locale   => 'en',
    user_model       => 'User',
    user_connection  => undef,
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
  die "Skinir: path must be a non-root path such as /admin\n"
    unless $cfg{path} =~ m{\A(?:/[A-Za-z0-9_-]+)+\z};
  die "Skinir: configure gate => sub { ... } explicitly to allow panel access\n"
    unless ref $cfg{gate} eq 'CODE';
  die "Skinir: per_page_options must contain page sizes from 1 to 100\n"
    unless ref($cfg{per_page_options}) eq 'ARRAY' && @{$cfg{per_page_options}}
      && !(grep { !defined $_ || ref $_ || !/\A[1-9][0-9]{0,2}\z/ || $_ > 100 } @{$cfg{per_page_options}});

  $self->app($app)->config(\%cfg);
  $self->{attempts} = {};

  die "Mojolicious::Plugin::Skinir: load the Yggdrasil plugin first (it provides the models).\n"
    unless _has_helper($app, 'yggdrasil');

  $self->_load_dependencies($app, \%cfg);
  $self->_load_lang;
  $self->user_class($app->yggdrasil->model($cfg{user_model}));
  die "Skinir: user model must have a single primary key\n" if ref $self->user_class->primary_key;
  $app->yggdrasil->make_model($cfg{user_model}, {}, using => $cfg{user_connection});
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
  Yggdrasil->VERSION('0.05');

  $app->plugin(Translatable => {default => $cfg->{default_locale}}) unless _has_helper($app, 'trans');
  $app->plugin(FormRequest => {}) unless _has_helper($app, 'form_request');
  # unique:/exists: rules query the same database as the models
  $app->config->{FormRequest}{db} //= sub ($c) { $c->yggdrasil->connection($c->stash('skinir.connection'))->dbh };
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

sub _passphrase ($self) {
  require Crypt::Passphrase;
  return $self->{passphrase} //= Crypt::Passphrase->new(encoder => 'Argon2', validators => ['Bcrypt']);
}

sub hash_password ($self, $c, $plain) {
  return $c->heimdall->password->hash($plain) if _has_helper($c->app, 'heimdall');
  return $self->_passphrase->hash_password($plain);
}

sub _verify_password ($self, $c, $plain, $hash) {
  return $c->heimdall->password->verify($plain, $hash) if _has_helper($c->app, 'heimdall');
  return $self->_passphrase->verify_password($plain, $hash);
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
    die "Skinir: invalid resource key '$key'\n" unless $key =~ /\A[a-z0-9][a-z0-9_-]*\z/;
    my $record = $self->record($res);
    die "Skinir: '$key' requires a single primary key\n" if ref $record->primary_key;
    die "Skinir: '$key' per_page must be between 1 and 100\n"
      unless $res->per_page =~ /\A[1-9][0-9]{0,2}\z/ && $res->per_page <= 100;
    die "Skinir: duplicate resource key '$key'\n" if $by{$key};
    $by{$key} = $res;
    push @list, $res;
  }
  $self->resources(\@list);
  $self->_by_key(\%by);
}

sub _register_policies ($self, $app, $cfg) {
  my %map = %{$cfg->{policies}};
  my %declared;
  for my $res (@{$self->resources}) {
    my $model = $self->record($res);
    my $name = $model->can('policy_name') ? $model->policy_name : ref $model;
    $name =~ s/\A.*::// unless $model->can('policy_name');
    next if exists $cfg->{policies}{$name};
    my $policy = $res->policy // 'Mojolicious::Plugin::Skinir::Policy';
    die "Skinir: conflicting policies for '$name'; configure one shared policy explicitly\n"
      if exists($declared{$name}) && $declared{$name} ne $policy;
    $map{$name} = $declared{$name} = $policy;
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

sub record ($self, $res) {
  return $self->app->yggdrasil->make_model($res->model, {}, using => $res->connection);
}

sub query ($self, $c, $res, %opts) {
  my $q = $self->app->yggdrasil->model_query($res->model, using => $res->connection, %opts);
  return $res->scope_query($c, $q) // $q;
}

sub valid_id ($self, $model, $id) {
  return 0 unless defined $id && !ref $id && $id =~ /\A[A-Za-z0-9_-]{1,64}\z/;
  return 1 unless $model->incrementing;
  return !!($id =~ /\A(?:0|[1-9][0-9]{0,18})\z/
    && (length($id) < 19 || $id le '9223372036854775807'));
}

sub _users ($self) {
  return $self->app->yggdrasil->model_query($self->config->{user_model}, using => $self->config->{user_connection});
}

sub new_user_record ($self) {
  return $self->app->yggdrasil->make_model($self->config->{user_model}, {}, using => $self->config->{user_connection});
}

sub user ($self, $c) {
  my $st = $c->stash;
  return $st->{'skinir.user'} if exists $st->{'skinir.user'};
  my $key = $self->config->{session_key};
  my $id = $c->session->{$key};
  my $until = $c->session->{"${key}_until"};
  my $u = defined $id && defined $until && $until > time ? $self->_users->find($id) : undef;
  return $st->{'skinir.user'} = $u;
}

sub may_enter ($self, $c, $user) {
  my $gate = $self->config->{gate};
  return $gate->($c, $user) ? 1 : 0;
}

# ---- authentication -------------------------------------------------------------------
sub throttled ($self, $c) {
  my $ip = $c->tx->remote_address // '?';
  my $cfg = $self->config;
  my $rec = $self->{attempts}{$ip};
  unless ($rec) {
    my $attempts = $self->{attempts};
    return 0 if keys(%$attempts) < 5000;
    my $now = time;
    delete $attempts->{$_} for grep { $now - $attempts->{$_}[1] >= $cfg->{login_window} } keys %$attempts;
    return keys(%$attempts) >= 5000;
  }
  if (time - $rec->[1] >= $cfg->{login_window}) { delete $self->{attempts}{$ip}; return 0 }
  return $rec->[0] >= $cfg->{login_attempts} ? 1 : 0;
}

sub _failed ($self, $c) {
  my $ip  = $c->tx->remote_address // '?';
  my $rec = $self->{attempts}{$ip} //= [0, time];
  $rec->[0]++;
}

sub attempt ($self, $c, $identifier, $password) {
  my $cfg   = $self->config;
  if (length($identifier // '') > 320 || length($password // '') > 1024) {
    $self->_failed($c);
    return undef;
  }
  my $user  = (defined $identifier && length $identifier && defined $password)
    ? $self->_users->where($cfg->{login_field}, $identifier)->first : undef;

  # always hash-verify so unknown accounts take as long as wrong passwords
  my $hash = $user ? $user->get_attribute($cfg->{password_field}) : undef;
  my $has_hash = defined $hash && length $hash;
  $hash = ($self->{dummy} //= $self->hash_password($c, 'skinir-dummy-password')) unless $has_hash;
  my $ok = eval { $self->_verify_password($c, $password // '', $hash) } ? 1 : 0;

  if ($user && $has_hash && $ok && $self->may_enter($c, $user)) {
    delete $self->{attempts}{$c->tx->remote_address // '?'};
    my $key = $cfg->{session_key};
    $c->session->{$key} = $user->get_key;
    $c->session->{"${key}_until"} = time + $cfg->{session_expires};
    delete $c->session->{csrf_token};
    $c->stash('skinir.user' => $user);
    return $user;
  }
  $self->_failed($c);
  return undef;
}

sub logout ($self, $c) {
  my $key = $self->config->{session_key};
  delete @{$c->session}{$key, "${key}_until", 'csrf_token'};
  delete $c->stash->{'skinir.user'};
}

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
  $self->app->log->warn("Skinir: unable to remove managed upload '$rel': $!") if -f "$f" && !unlink "$f";
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
  $r->post('/export')->to('resources#export_csv');
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
  $c->res->headers->cache_control('no-store');
  my $u = $self->user($c);
  return 1 if $u && $self->may_enter($c, $u);
  $c->session(skinir_return_to => $c->req->url->path->to_string) if $c->req->method eq 'GET';
  $c->redirect_to($self->url('login'));
  return undef;
}

sub _guard_api ($self, $c) {
  $c->res->headers->cache_control('no-store');
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
    gate      => sub { $_[1]->get_attribute('is_admin') },
  });

=head1 DESCRIPTION

Skinir builds an admin panel from resource classes. It composes Yggdrasil
(models), FormRequest (validation), Policy (authorization) and Translatable
(i18n). Login uses Mojolicious sessions and Argon2 by default. See the README
and user guide for installation, permission setup and the SQLite demo.

=cut
