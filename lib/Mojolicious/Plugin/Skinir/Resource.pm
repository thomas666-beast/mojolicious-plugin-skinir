package Mojolicious::Plugin::Skinir::Resource;
use Mojo::Base -base, -signatures;

use Mojo::Util qw(decamelize);

# Subclass and override what you need:
#
#   package MyApp::Resource::Post;
#   use Mojo::Base 'Mojolicious::Plugin::Skinir::Resource', -signatures;
#   use Mojolicious::Plugin::Skinir::Fields;
#   sub model  { 'Post' }
#   sub title  { 'title' }
#   sub search { [qw(title body)] }
#   sub fields ($self, $c) {[ ID(), Text('Title')->sortable->rules('required') ]}

sub model ($self) { die ref($self) . ": model() must return the model name, e.g. 'User'\n" }

sub _basename ($self) { (my $n = ref $self) =~ s/\A.*:://; $n }

sub _humanize ($name) {
  my $s = decamelize($name);
  return join ' ', map { ucfirst } split /_/, $s;
}

sub _plural ($word) {
  return $word . 'es' if $word =~ /(?:s|x|z|ch|sh)\z/;
  return substr($word, 0, -1) . 'ies' if $word =~ /[^aeiou]y\z/;
  return $word . 's';
}

sub uri_key ($self) {
  return $self->{uri_key} //= do {
    my @w = split /_/, decamelize($self->_basename);
    $w[-1] = _plural($w[-1]);
    join '-', @w;
  };
}

sub singular_label ($self) { _humanize($self->_basename) }

sub label ($self) {
  my @w = split / /, _humanize($self->_basename);
  $w[-1] = ucfirst _plural(lc $w[-1]);
  return join ' ', @w;
}

sub title    ($self) { 'id' }            # column name, or a coderef ($model) -> string
sub search   ($self) { [] }              # columns searched with ILIKE
sub per_page ($self) { 25 }
sub group    ($self) { 'Resources' }
sub icon     ($self) { 'collection' }
sub policy   ($self) { undef }           # class name; default: allow any panel user
sub eager    ($self) { [] }              # relations to include() on the index query
sub order    ($self) { undef }           # e.g. [['created_at', 'desc']]
sub connection ($self) { undef }         # named Yggdrasil connection for unique/exists rules

sub fields  ($self, $c) { [] }
sub filters ($self, $c) { [] }
sub actions ($self, $c) { [] }
sub cards   ($self, $c) { [] }

# ---- hooks ---------------------------------------------------------------------------
sub index_query  ($self, $c, $q) { $q }
sub before_save  ($self, $c, $model, $mode) { }    # $mode: create | update
sub after_save   ($self, $c, $model, $mode) { }
sub before_delete ($self, $c, $model) { }
sub after_delete  ($self, $c, $model) { }

sub title_of ($self, $model) {
  my $t = $self->title;
  my $v = ref $t eq 'CODE' ? $t->($model) : $model->get_attribute($t);
  return defined $v && length $v ? "$v" : '#' . ($model->get_key // '');
}

1;
