package Mojolicious::Command::skinir;
use Mojo::Base 'Mojolicious::Command', -signatures;

use Mojo::File qw(path);
use Mojo::UserAgent;
use Mojo::Util qw(getopt);

our $VERSION = '0.01';

has description => 'Skinir admin panel tools';
has usage       => <<'USAGE';
Usage: APPLICATION skinir <subcommand> [args]

  make:resource <Name> [--model Model]   Create lib/<App>/Resource/<Name>.pm
  make:policy   <Name>                   Create lib/<App>/Policy/<Name>.pm (extends the Skinir policy)
  make:user     <email> [name]           Create a panel user (prompts for the password)
  assets:vue [--version 3.5.13]          Download Vue into public/skinir/vendor/ (then set vue => 'local')
USAGE

sub run ($self, @args) {
  my $sub = shift @args // '';
  return say $self->usage unless $sub;
  my %map = (
    'make:resource' => '_make_resource',
    'make:policy'   => '_make_policy',
    'make:user'     => '_make_user',
    'assets:vue'    => '_assets_vue',
  );
  my $m = $map{$sub} or do { say "Unknown subcommand: $sub"; return say $self->usage };
  return $self->$m(@args);
}

sub _write ($self, $file, $content) {
  if (-e $file) { say "File already exists: $file"; return 0 }
  $file->dirname->make_path;
  $file->spew($content);
  say "Created: $file";
  return 1;
}

sub _target ($self, $dir, $name) {
  my $app = ref $self->app;
  return path($self->app->home, 'lib', split(/::/, $app), $dir, split(m{/}, $name))->to_string . '.pm';
}

sub _make_resource ($self, @args) {
  my $model;
  getopt \@args, 'model=s' => \$model;
  my $name = shift @args or return say 'Usage: APPLICATION skinir make:resource <Name> [--model Model]';
  return say "Invalid name: $name" unless $name =~ m{\A[A-Z][A-Za-z0-9]*(?:/[A-Z][A-Za-z0-9]*)*\z};

  (my $base = $name) =~ s{.*/}{};
  $model //= $base;
  my $app = ref $self->app;
  my $pkg = "${app}::Resource::" . join('::', split m{/}, $name);

  my $code = <<"EOF2";
package $pkg;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Resource', -signatures;
use Mojolicious::Plugin::Skinir::Fields;

sub model  { '$model' }
sub title  { 'id' }                 # column used as the row title
sub search { [] }                   # columns searched from the index screen
# sub group { 'Content' }
# sub icon  { 'document' }          # see the icon list in the README

sub fields (\$self, \$c) {[
  ID(),
  # Text('Name')->sortable->rules('required|max:255'),
]}

# sub filters (\$self, \$c) {[ ]}
# sub actions (\$self, \$c) {[ ]}
# sub cards   (\$self, \$c) {[ ]}

1;
EOF2
  $self->_write(path($self->_target('Resource', $name)), $code) or return;
  say "Resources in $app\::Resource are discovered automatically.";
}

sub _make_policy ($self, @args) {
  my $name = shift @args or return say 'Usage: APPLICATION skinir make:policy <Name>';
  return say "Invalid name: $name" unless $name =~ /\A[A-Z][A-Za-z0-9]*\z/;
  my $app = ref $self->app;
  my $pkg = "${app}::Policy::$name";
  my $code = <<"EOF2";
package $pkg;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Policy', -signatures;

# Inherited defaults allow every signed-in panel user.
# Override per ability; each receives (\$self, \$c, \$model) and returns true to allow.
# view_any and create receive a blank model.

# sub update (\$self, \$c, \$model) { \$c->skinir_user->get_attribute('role') eq 'admin' }
# sub delete (\$self, \$c, \$model) { 0 }

1;
EOF2
  return unless $self->_write(path($self->_target('Policy', $name)), $code);
  say "Register it on the resource:  sub policy { '$pkg' }";
}

sub _make_user ($self, @args) {
  my ($email, $name) = @args;
  return say 'Usage: APPLICATION skinir make:user <email> [name]' unless $email;
  my $s   = $self->app->skinir or return say 'The Skinir plugin is not loaded.';
  my $cfg = $s->config;

  my $pw = $ENV{SKINIR_PASSWORD};
  unless (defined $pw && length $pw) {
    require IO::Handle;
    print 'Password: '; STDOUT->flush;
    system('stty', '-echo') if -t STDIN;
    chomp($pw = <STDIN> // '');
    system('stty', 'echo') if -t STDIN;
    print "\n";
  }
  return say 'Password must be at least 10 characters.' unless length($pw) >= 10;

  my $class = $s->user_class;
  return say "A user with that $cfg->{login_field} already exists."
    if $class->query->where($cfg->{login_field}, $email)->first;

  my $c = $self->app->build_controller;
  my %attrs = (
    $cfg->{login_field}    => $email,
    $cfg->{name_field}     => ($name // $email),
    $cfg->{password_field} => $c->heimdall->password->hash($pw),
  );
  my $u = $class->new;
  $u->force_fill(\%attrs);
  $u->save;
  say "Created user #" . $u->get_key . " <$email>";
}

sub _assets_vue ($self, @args) {
  my $version = '3.5.13';
  getopt \@args, 'version=s' => \$version;
  return say 'Invalid version' unless $version =~ /\A\d+\.\d+\.\d+\z/;
  my $url  = "https://cdn.jsdelivr.net/npm/vue\@$version/dist/vue.global.prod.js";
  my $dest = path($self->app->home, 'public', 'skinir', 'vendor', 'vue.global.prod.js');
  my $res  = Mojo::UserAgent->new(max_redirects => 3)->get($url)->result;
  return say "Download failed: " . $res->message unless $res->is_success;
  $dest->dirname->make_path;
  $dest->spew($res->body);
  say "Saved $dest (" . length($res->body) . " bytes)";
  say "Now set  vue => 'local'  in the Skinir plugin configuration.";
}

1;
