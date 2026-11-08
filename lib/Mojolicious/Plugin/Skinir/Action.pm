package Mojolicious::Plugin::Skinir::Action;
use Mojo::Base -base, -signatures;

# An action runs on the selected rows of a resource (or standalone).
#
#   Mojolicious::Plugin::Skinir::Action->new(
#     name   => 'Publish',
#     fields => [ Select('Visibility')->options({public => 'Public'}) ],
#     handler => sub ($c, $models, $fields) { ...; return {message => 'Done'} },
#   );
#
# Or subclass it and override handle().

has [qw(name key fields confirm_text confirm_button handler)];
has destructive => 0;
has standalone  => 0;
has ability     => undef;     # policy ability required per row (default: update / delete)

sub new ($class, @args) {
  my $self = $class->SUPER::new(@args);
  unless (defined $self->{key}) {
    (my $k = lc($self->{name} // 'action')) =~ s/[^a-z0-9]+/-/g;
    $k =~ s/\A-+|-+\z//g;
    $self->{key} = $k;
  }
  return $self;
}

sub handle ($self, $c, $models, $fields) {
  my $cb = $self->{handler} // die ref($self) . ": no handler given\n";
  return $cb->($c, $models, $fields);
}

sub required_ability ($self) { $self->{ability} // ($self->{destructive} ? 'delete' : 'update') }

sub field_list ($self, $c) {
  my $f = $self->{fields} // [];
  return ref $f eq 'CODE' ? $f->($c) : $f;
}

sub meta ($self, $c, $resource) {
  my $key = $resource->uri_key;
  return {
    key            => $self->{key},
    name           => $c->skinir->tr_or($c, "actions.$key.$self->{key}", $self->{name}),
    destructive    => ($self->{destructive} ? \1 : \0),
    standalone     => ($self->{standalone}  ? \1 : \0),
    confirm_text   => $self->{confirm_text},
    confirm_button => $self->{confirm_button},
    fields         => [map { $_->meta($c, $resource) } @{$self->field_list($c)}],
  };
}

1;
