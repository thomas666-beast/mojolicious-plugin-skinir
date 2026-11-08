package Mojolicious::Plugin::Skinir::Fields;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
use Mojolicious::Plugin::Skinir::Field;

our @EXPORT = qw(
  ID Text Textarea Number Boolean Select Date DateTime Email Url Password
  Color Code Badge BelongsTo HasMany Image File
);

sub _slug ($label) {
  my $a = lc $label;
  $a =~ s/[^a-z0-9]+/_/g;
  $a =~ s/\A_+|_+\z//g;
  return $a;
}

sub _mk ($type, $label, $attr, %extra) {
  return Mojolicious::Plugin::Skinir::Field->new(
    type      => $type,
    label     => $label,
    attribute => $attr // _slug($label),
    %extra,
  );
}

sub ID ($label = 'ID', $attr = 'id') {
  return _mk('id', $label, $attr)->sortable->readonly->hide_when_creating->hide_when_updating;
}

sub Text     ($label, $attr = undef) { _mk('text',     $label, $attr) }
sub Textarea ($label, $attr = undef) { _mk('textarea', $label, $attr)->hide_from_index }
sub Number   ($label, $attr = undef) { _mk('number',   $label, $attr) }
sub Boolean  ($label, $attr = undef) { _mk('boolean',  $label, $attr) }
sub Select   ($label, $attr = undef) { _mk('select',   $label, $attr) }
sub Date     ($label, $attr = undef) { _mk('date',     $label, $attr) }
sub DateTime ($label, $attr = undef) { _mk('datetime', $label, $attr) }
sub Email    ($label = 'Email', $attr = undef) { _mk('email', $label, $attr) }
sub Url      ($label, $attr = undef) { _mk('url',      $label, $attr) }
sub Color    ($label, $attr = undef) { _mk('color',    $label, $attr) }
sub Code     ($label, $attr = undef) { _mk('code',     $label, $attr)->hide_from_index }
sub Badge    ($label, $attr = undef) { _mk('badge',    $label, $attr)->readonly }
sub Image    ($label, $attr = undef) { _mk('image',    $label, $attr) }
sub File     ($label, $attr = undef) { _mk('file',     $label, $attr) }

# Password is never displayed; a blank value on update keeps the stored hash.
sub Password ($label = 'Password', $attr = undef) {
  return _mk('password', $label, $attr)->only_on_forms;
}

# BelongsTo('Author', 'user_id', 'users')   -- $resource is a resource key or class
sub BelongsTo ($label, $attr, $resource) {
  return _mk('belongs_to', $label, $attr, resource => $resource);
}

# HasMany('Posts', 'posts', 'posts')   -- relation method on the model, related resource
sub HasMany ($label, $relation, $resource) {
  return _mk('has_many', $label, $relation, resource => $resource, relation => $relation)->only_on_detail;
}

1;

__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Skinir::Fields - field constructors (Nova style)

=head1 SYNOPSIS

  use Mojolicious::Plugin::Skinir::Fields;

  sub fields ($self, $c) {[
    ID(),
    Text('Title')->sortable->rules('required|max:150'),
    Select('Status')->options({draft => 'Draft', live => 'Live'})->sortable,
    BelongsTo('Author', 'user_id', 'users')->searchable,
    Boolean('Featured'),
    Image('Cover')->max_kb(2048),
    HasMany('Comments', 'comments', 'comments'),
  ]}

=head1 FUNCTIONS

C<ID>, C<Text>, C<Textarea>, C<Number>, C<Boolean>, C<Select>, C<Date>,
C<DateTime>, C<Email>, C<Url>, C<Password>, C<Color>, C<Code> (JSON),
C<Badge>, C<BelongsTo>, C<HasMany>, C<Image>, C<File>.

Each returns a L<Mojolicious::Plugin::Skinir::Field>. The first argument is the
label; the attribute (column) defaults to the snake-cased label and can be given
as the second argument.

=cut
