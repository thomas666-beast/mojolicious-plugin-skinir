package Mojolicious::Plugin::Skinir::Filter;
use Mojo::Base -base, -signatures;

use Exporter 'import';
use Mojo::JSON qw(true false);
our @EXPORT_OK = qw(SelectFilter BooleanFilter TextFilter DateFilter);

has [qw(label attribute type key options handler)];

sub new ($class, @args) {
  my $self = $class->SUPER::new(@args);
  $self->{key} //= $self->{attribute};
  return $self;
}

sub SelectFilter  ($label, $attr, $options) { __PACKAGE__->new(type => 'select',  label => $label, attribute => $attr, options => $options) }
sub BooleanFilter ($label, $attr)           { __PACKAGE__->new(type => 'boolean', label => $label, attribute => $attr) }
sub TextFilter    ($label, $attr)           { __PACKAGE__->new(type => 'text',    label => $label, attribute => $attr) }
sub DateFilter    ($label, $attr)           { __PACKAGE__->new(type => 'date',    label => $label, attribute => $attr) }

# ->using(sub ($c, $query, $value) { ... }) replaces the default behaviour
sub using ($self, $cb) { $self->{handler} = $cb; $self }

sub option_list ($self) {
  my $o = $self->{options} // return [];
  return [map { +{value => $_, label => "$o->{$_}"} } sort { lc "$o->{$a}" cmp lc "$o->{$b}" } keys %$o] if ref $o eq 'HASH';
  return [map { ref $_ eq 'ARRAY' ? +{value => $_->[0], label => $_->[1] // $_->[0]} : +{value => $_, label => "$_"} } @$o];
}

sub valid_input ($self, $v) {
  my $t = $self->type;
  if ($t eq 'date') {
    return ref $v eq 'HASH' && !grep {
      $_ !~ /\A(?:from|to)\z/ || (defined($v->{$_}) && (ref($v->{$_}) || $v->{$_} !~ /\A(?:[0-9]{4}-[0-9]{2}-[0-9]{2})?\z/))
    } keys %$v;
  }
  return 1 if $t eq 'boolean' && ref $v && (ref($v) eq ref(true) || ref($v) eq ref(false));
  return 0 if ref $v || length($v) > 200;
  return scalar grep { $_->{value} eq $v } @{$self->option_list} if $t eq 'select';
  return $v =~ /\A(?:0|1|true|false)\z/i if $t eq 'boolean';
  return 1;
}

sub apply ($self, $c, $q, $value) {
  return $self->{handler}->($c, $q, $value) if $self->{handler};

  my ($t, $col) = ($self->{type}, $self->{attribute});
  if ($t eq 'select') {
    return unless grep { $_->{value} eq $value } @{$self->option_list};   # whitelist
    $q->where($col, $value);
  }
  elsif ($t eq 'boolean') {
    $q->where($col, $value =~ /\A(?:1|true)\z/i ? 1 : 0);
  }
  elsif ($t eq 'text') {
    $q->where($col, 'ilike', "%$value%");
  }
  elsif ($t eq 'date' && ref $value eq 'HASH') {
    my ($from, $to) = @{$value}{qw(from to)};
    $q->where($col, '>=', "$from 00:00:00") if defined $from && $from =~ /\A\d{4}-\d\d-\d\d\z/;
    $q->where($col, '<=', "$to 23:59:59")   if defined $to   && $to   =~ /\A\d{4}-\d\d-\d\d\z/;
  }
  return;
}

sub meta ($self, $c = undef) {
  my $label = $self->{label};
  if ($c && $c->can('skinir')) {
    $label = $c->skinir->tr_or($c, "filters.$self->{key}", $label);
  }
  return {
    key     => $self->{key},
    label   => $label,
    type    => $self->{type},
    options => ($self->{type} eq 'select' ? $self->option_list : undef),
  };
}

1;

__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Skinir::Filter - index-screen filters

=head1 SYNOPSIS

  use Mojolicious::Plugin::Skinir::Filter qw(SelectFilter BooleanFilter DateFilter);

  sub filters ($self, $c) {[
    SelectFilter('Status', 'status', {draft => 'Draft', live => 'Live'}),
    BooleanFilter('Featured', 'featured'),
    DateFilter('Created', 'created_at'),
    SelectFilter('Mine', 'mine', {1 => 'My posts'})
      ->using(sub ($c, $q, $v) { $q->where(user_id => $c->skinir_user->get_key) }),
  ]}

=cut
