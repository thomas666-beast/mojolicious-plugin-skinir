package Mojolicious::Plugin::Skinir::Field;
use Mojo::Base -base, -signatures;

use Mojo::JSON qw(decode_json);
use Mojo::Util qw(sha1_sum);
use Scalar::Util qw(blessed looks_like_number);

our @CONTEXTS = qw(index detail create update);

# ---------------------------------------------------------------------------
# Fluent accessors.  $f->help('x') sets (and returns $f); $f->help gets.
# ---------------------------------------------------------------------------
my @PROPS = qw(
  help placeholder default prefix suffix step min max rows resource relation
  display_using fill_using computed badge_types badge_labels max_kb mimes
  rows_limit
);
my @FLAGS = qw(sortable readonly nullable required integer searchable);

for my $p (@PROPS) {
  no strict 'refs';
  *{__PACKAGE__ . "::$p"} = sub ($self, @v) {
    return $self->{$p} unless @v;
    $self->{$p} = $v[0];
    return $self;
  };
}

for my $f (@FLAGS) {
  no strict 'refs';
  *{__PACKAGE__ . "::$f"}      = sub ($self, $v = 1) { $self->{$f} = $v ? 1 : 0; $self };
  *{__PACKAGE__ . "::is_$f"}   = sub ($self) { $self->{$f} ? 1 : 0 };
}

sub new ($class, @args) {
  my $self = $class->SUPER::new(@args);
  $self->{show} //= {map { $_ => 1 } @CONTEXTS};
  return $self;
}

sub type      ($self) { $self->{type} }
sub label     ($self) { $self->{label} }
sub attribute ($self) { $self->{attribute} }

# ---- visibility ---------------------------------------------------------------
sub shown_on ($self, $ctx) { $self->{show}{$ctx} ? 1 : 0 }

sub hide_from_index   ($self) { $self->{show}{index}  = 0; $self }
sub hide_from_detail  ($self) { $self->{show}{detail} = 0; $self }
sub hide_when_creating ($self) { $self->{show}{create} = 0; $self }
sub hide_when_updating ($self) { $self->{show}{update} = 0; $self }

sub only_on_index  ($self) { $self->{show} = {index => 1, detail => 0, create => 0, update => 0}; $self }
sub only_on_detail ($self) { $self->{show} = {index => 0, detail => 1, create => 0, update => 0}; $self }
sub only_on_forms  ($self) { $self->{show} = {index => 0, detail => 0, create => 1, update => 1}; $self }
sub except_on_forms ($self) { $self->{show}{create} = 0; $self->{show}{update} = 0; $self }

# A computed field has no column: ->using(sub ($model, $c) { ... })
sub using ($self, $cb) {
  $self->{computed} = $cb;
  $self->{readonly} = 1;
  return $self->except_on_forms;
}

# ---- validation rules ---------------------------------------------------------
sub rules          ($self, @r) { push @{$self->{rules}},          @r; $self }
sub creation_rules ($self, @r) { push @{$self->{creation_rules}}, @r; $self }
sub update_rules   ($self, @r) { push @{$self->{update_rules}},   @r; $self }

# ->unique  /  ->unique($table, $column)   (the current row is ignored on update)
sub unique ($self, $table = undef, $column = undef) {
  $self->{unique} = {table => $table, column => $column};
  return $self;
}

# ---- select / badge options ---------------------------------------------------
# options({ draft => 'Draft' })  |  options([qw(a b)])  |  options([[a => 'A'], ...])
# |  options(sub ($c) { ... })
sub options ($self, @v) {
  return $self->{options} unless @v;
  $self->{options} = $v[0];
  return $self;
}

sub option_list ($self, $c = undef) {
  my $o = $self->{options};
  $o = $o->($c) if ref $o eq 'CODE';
  return [] unless defined $o;
  if (ref $o eq 'HASH') {
    return [map { +{value => $_, label => "$o->{$_}"} } sort { lc "$o->{$a}" cmp lc "$o->{$b}" } keys %$o];
  }
  return [
    map {
      ref $_ eq 'HASH'  ? {value => $_->{value}, label => $_->{label} // $_->{value}}
    : ref $_ eq 'ARRAY' ? {value => $_->[0], label => $_->[1] // $_->[0]}
    :                     {value => $_, label => "$_"}
    } @$o
  ];
}

# badge: ->types({ published => 'success' })  ->labels({ published => 'Live' })
sub types  ($self, $v) { $self->{badge_types}  = $v; $self }
sub labels ($self, $v) { $self->{badge_labels} = $v; $self }

# ---- helpers ------------------------------------------------------------------
sub _is_text_like ($self) { $self->{type} =~ /\A(?:text|textarea|email|url|code)\z/ ? 1 : 0 }
sub _is_upload    ($self) { $self->{type} =~ /\A(?:image|file)\z/ ? 1 : 0 }

sub is_fillable ($self) {
  return 0 if $self->{readonly} || $self->{computed};
  return 0 if $self->{type} =~ /\A(?:id|has_many|badge)\z/;
  return 1;
}

sub _iso ($v) {
  return undef unless defined $v && length $v;
  return "$v" if $v =~ /Z\z|[+-]\d\d:?\d\d\z/;       # already zoned
  (my $s = "$v") =~ s/ /T/;
  $s .= ':00' if $s =~ /T\d\d:\d\d\z/;
  return $s =~ /T/ ? "${s}Z" : $s;
}

sub _from_iso ($v) {
  (my $s = "$v") =~ s/T/ /;
  $s =~ s/Z\z//;
  $s =~ s/\.\d+\z//;
  $s .= ':00' if $s =~ / \d\d:\d\d\z/;
  return $s;
}

sub _bool ($v) {
  return 0 unless defined $v;
  return 1 if ref $v && "$v" eq '1';
  return 0 if ref $v;
  return $v =~ /\A(?:1|true|on|yes|t|y)\z/i ? 1 : 0;
}

# ---- value in / out -----------------------------------------------------------
sub raw ($self, $c, $model) {
  return $self->{computed}->($model, $c) if $self->{computed};
  return $model->get_attribute($self->{attribute});
}

# Value shown on index / detail screens
sub display ($self, $c, $model) {
  my ($t, $v) = ($self->{type}, $self->raw($c, $model));

  return undef if $t eq 'password' || $t eq 'has_many';
  return (_bool($v) ? \1 : \0) if $t eq 'boolean';
  return _iso($v) if $t eq 'datetime';
  return $self->_json_text($v) if $t eq 'json' || $t eq 'code';
  return $self->_upload_value($c, $v) if $self->_is_upload;

  if ($t eq 'belongs_to') {
    return undef unless defined $v && length $v;
    return {id => $v, title => $self->{_titles}{$v} // "#$v"};
  }

  return undef unless defined $v;
  if ($self->{display_using}) {
    $v = $self->{display_using}->($v, $model, $c);
    return defined $v ? "$v" : undef;
  }
  return 0 + $v if $t eq 'number' && looks_like_number($v);
  return ref $v ? "$v" : $v;
}

# Value placed into a form input
sub form_value ($self, $c, $model) {
  my $t = $self->{type};
  return undef if $t eq 'password';
  if (!$model->in_storage) {
    my $d = $self->{default};
    $d = $d->($c) if ref $d eq 'CODE';
    return $t eq 'boolean' ? (_bool($d) ? \1 : \0) : $d;
  }
  return $self->display($c, $model) if $t ne 'belongs_to';
  my $v = $self->raw($c, $model);
  return $v;
}

sub _json_text ($self, $v) {
  return undef unless defined $v;
  return $v unless ref $v;
  require JSON::PP;
  return JSON::PP->new->canonical->pretty->allow_nonref->encode($v);
}

# ---- belongs_to / has_many ------------------------------------------------------
sub related_resource ($self, $c) {
  my $ref = $self->{resource} // return undef;
  return $c->skinir->resource($ref);
}

# Batch-load the titles of related rows for a page of models (one query).
sub prefetch ($self, $c, $models) {
  return unless $self->{type} eq 'belongs_to' && @$models;
  my $rres = $self->related_resource($c) or return;
  my $rcls = $c->model($rres->model);
  my %seen;
  my @ids = grep { defined $_ && length $_ && !$seen{$_}++ } map { $_->get_attribute($self->{attribute}) } @$models;
  return unless @ids;
  my $rows = $rcls->query->where_in($rcls->primary_key, \@ids)->get;
  $self->{_titles}{$_->get_key} = $rres->title_of($_) for @$rows;
  return;
}

# Detail-page panel for a has_many field
sub panel ($self, $c, $model, $limit = 5) {
  my $rres = $self->related_resource($c) or return undef;
  my $rel  = $self->{relation} // $self->{attribute};
  return undef unless $model->can($rel);
  my $total = $model->$rel->count;
  my @rows  = map { +{id => $_->get_key, title => $rres->title_of($_)} } @{$model->$rel->limit($limit)->get};
  return {
    attribute => $self->{attribute},
    label     => $self->{label},
    resource  => $rres->uri_key,
    total     => $total,
    rows      => \@rows,
  };
}

# ---- uploads ----------------------------------------------------------------------
sub _upload_value ($self, $c, $v) {
  return undef unless defined $v && length $v;
  my $url = $c->skinir->upload_url($v);
  (my $name = $v) =~ s{^.*/}{};
  return {path => $v, url => $url, name => $name, image => ($self->{type} eq 'image' ? \1 : \0)};
}

sub allowed_extensions ($self) {
  return $self->{mimes} if $self->{mimes};
  return [qw(jpg jpeg png gif webp)] if $self->{type} eq 'image';
  return [qw(pdf txt csv zip doc docx xls xlsx ppt pptx png jpg jpeg gif webp)];
}

sub _upload ($self, $c) { $c->req->upload($self->{attribute}) }

# Returns an error string, or undef when the upload (or its absence) is fine.
sub check_upload ($self, $c, $mode) {
  my $up = $self->_upload($c);
  unless ($up && $up->size) {
    return 'is required' if $mode eq 'create' && $self->_declares_required('create');
    return undef;
  }
  my $max = ($self->{max_kb} // 5120) * 1024;
  return 'is too large' if $up->size > $max;
  my ($ext) = lc($up->filename // '') =~ /\.([a-z0-9]+)\z/;
  return 'has an unsupported file type' unless defined $ext && grep { $_ eq $ext } @{$self->allowed_extensions};
  return undef;
}

sub _store_upload ($self, $c, $model) {
  my $up = $self->_upload($c);
  my $old = $model->get_attribute($self->{attribute});

  if ($up && $up->size) {
    my ($ext) = lc($up->filename) =~ /\.([a-z0-9]+)\z/;
    my $rel   = join '/', 'skinir', $c->stash('skinir.resource_key') // 'files',
      sha1_sum(join ':', $$, time, rand, $up->filename) . ".$ext";
    my $dest = $c->skinir->upload_path($rel);
    $dest->dirname->make_path;
    $up->move_to("$dest");
    $c->skinir->delete_upload($old) if defined $old && length $old;
    $model->set_attribute($self->{attribute}, $rel);
  }
  elsif ($c->param("__clear_$self->{attribute}")) {
    $c->skinir->delete_upload($old) if defined $old && length $old;
    $model->set_attribute($self->{attribute}, undef);
  }
  return;
}

# ---- rules ------------------------------------------------------------------------
sub _rule_fragments ($self, $mode) {
  my $key = $mode eq 'create' ? 'creation_rules' : 'update_rules';
  return (@{$self->{rules} // []}, @{$self->{$key} // []});
}

sub _rules_text ($self, $mode) {
  return join '|', grep { !ref $_ } $self->_rule_fragments($mode);
}

sub _declares_required ($self, $mode) {
  return 1 if $self->{required};
  return $self->_rules_text($mode) =~ /(?:\A|\|)required(?:\z|[:|])/ ? 1 : 0;
}

# Build the FormRequest rule spec for this field, or undef when it is not validated.
sub compile_rules ($self, $c, $mode, $class, $record_id = undef) {
  return undef unless $self->is_fillable && $self->shown_on($mode);
  return undef if $self->_is_upload;

  my $t    = $self->{type};
  my @user = $self->_rule_fragments($mode);
  my $text = join '|', grep { !ref $_ } @user;

  my $in_text  = $text =~ /(?:\A|\|)required(?:\z|[:|])/ ? 1 : 0;
  my $required = $self->{required} || $in_text;
  my @parts;
  push @parts, $required ? ($in_text ? () : 'required') : 'nullable';

  # type derived rules
  push @parts, 'email'   if $t eq 'email';
  push @parts, 'url'     if $t eq 'url';
  push @parts, 'boolean' if $t eq 'boolean';
  push @parts, 'date'    if $t eq 'date';
  push @parts, 'json'    if $t eq 'json' || $t eq 'code';
  if ($t eq 'number') {
    push @parts, $self->{integer} ? 'integer' : 'numeric';
    push @parts, "min:$self->{min}" if defined $self->{min} && looks_like_number($self->{min});
    push @parts, "max:$self->{max}" if defined $self->{max} && looks_like_number($self->{max});
  }
  if ($t eq 'belongs_to') {
    if (my $rres = $self->related_resource($c)) {
      my $rcls = $c->model($rres->model);
      push @parts, 'exists:' . $rcls->table . ',' . $rcls->primary_key;
    }
  }
  if ($self->{unique}) {
    my $table  = $self->{unique}{table}  // $class->table;
    my $column = $self->{unique}{column} // $self->{attribute};
    push @parts, defined $record_id
      ? "unique:$table,$column,$record_id," . $class->primary_key
      : "unique:$table,$column";
  }

  my @code;
  if ($t eq 'select') {
    my %ok = map { ($_->{value} => 1) } @{$self->option_list($c)};
    push @code, sub ($value, $args, $params, $ctx) { exists $ok{$value} };
  }
  elsif ($t eq 'datetime') {
    push @code, sub ($value, $args, $params, $ctx) {
      defined $value && "$value" =~ /\A\d{4}-\d\d-\d\d[T ]\d\d:\d\d(?::\d\d(?:\.\d+)?)?(?:Z)?\z/;
    };
  }
  elsif ($t eq 'color') {
    push @code, sub ($value, $args, $params, $ctx) { defined $value && "$value" =~ /\A#[0-9a-fA-F]{6}\z/ };
  }

  my @strings = (@parts, grep { !ref $_ } @user);
  my @refs    = grep { ref $_ } @user;

  # string-only specs go through FormRequest's own splitter ("a|b:1,2|c")
  return join('|', grep { length } @strings) unless @refs || @code;

  my @list;
  for my $s (@strings) {
    if ($s =~ /(?:\A|\|)regex:/) { push @list, $s; next }
    push @list, grep { length } split /\|/, $s;
  }
  return [@list, @code, @refs];
}

# ---- hydrating a model ----------------------------------------------------------
sub _normalize ($self, $v) {
  my $t = $self->{type};
  return (_bool($v) ? 1 : 0) if $t eq 'boolean';

  my $empty = !defined $v || (!ref $v && $v eq '');
  if ($empty) {
    return undef if !$self->_is_text_like || $self->{nullable};
    return '';
  }
  return 0 + $v if $t eq 'number' && looks_like_number($v);
  return _from_iso($v) if $t eq 'datetime';
  return $v;
}

sub fill ($self, $c, $model, $data) {
  return unless $self->is_fillable;

  if ($self->_is_upload) {
    $self->_store_upload($c, $model);
    return;
  }

  my $attr = $self->{attribute};
  unless (exists $data->{$attr}) {
    $model->set_attribute($attr, 0) if $self->{type} eq 'boolean' && !$model->in_storage;
    return;
  }
  my $v = $data->{$attr};

  if ($self->{type} eq 'password') {
    return unless defined $v && length $v;               # blank = keep current hash
    $v = $c->heimdall->password->hash($v);
    $model->set_attribute($attr, $v);
    return;
  }

  $v = $self->_normalize($v);

  if (($self->{type} eq 'json' || $self->{type} eq 'code') && defined $v) {
    my $cast = $model->casts->{$attr} // '';
    $v = decode_json($v) if $cast =~ /\A(?:json|array|hash|object)\z/ && !ref $v;
  }

  return $self->{fill_using}->($c, $model, $v) if $self->{fill_using};
  $model->set_attribute($attr, $v);
  return;
}

# ---- metadata for the Vue client ------------------------------------------------
sub meta ($self, $c, $resource) {
  my $t = $self->{type};
  my %m = (
    attribute   => $self->{attribute},
    label       => $c->skinir->field_label($c, $resource, $self),
    type        => $t,
    sortable    => ($self->{sortable} && !$self->{computed} ? \1 : \0),
    readonly    => ($self->{readonly} ? \1 : \0),
    nullable    => ($self->{nullable} ? \1 : \0),
    required    => ($self->_declares_required('create') || $self->_declares_required('update') ? \1 : \0),
    help        => $self->{help},
    placeholder => $self->{placeholder},
    show        => {map { ($_ => ($self->{show}{$_} ? \1 : \0)) } @CONTEXTS},
  );
  $m{prefix} = $self->{prefix} if defined $self->{prefix};
  $m{suffix} = $self->{suffix} if defined $self->{suffix};

  if ($t eq 'select') { $m{options} = $self->option_list($c) }
  if ($t eq 'badge') {
    $m{types}  = $self->{badge_types}  // {};
    $m{labels} = $self->{badge_labels} // {};
  }
  if ($t eq 'number') {
    $m{min}  = $self->{min}  if defined $self->{min};
    $m{max}  = $self->{max}  if defined $self->{max};
    $m{step} = $self->{step} // ($self->{integer} ? 1 : 'any');
  }
  if ($t eq 'textarea') { $m{rows} = $self->{rows} // 5 }
  if ($t eq 'belongs_to' || $t eq 'has_many') {
    if (my $rres = $self->related_resource($c)) {
      $m{resource}   = $rres->uri_key;
      $m{searchable} = $self->{searchable} ? \1 : \0;
    }
  }
  if ($self->_is_upload) {
    $m{accept} = join ',', map {".$_"} @{$self->allowed_extensions};
  }
  return \%m;
}

1;

__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Skinir::Field - a column of a Skinir resource

=head1 SYNOPSIS

  use Mojolicious::Plugin::Skinir::Fields;

  Text('Name')->sortable->rules('required|max:255');
  Email('Email')->unique->rules('required');
  Select('Status')->options({draft => 'Draft', live => 'Live'});
  BelongsTo('Author', 'user_id', 'users');

See L<Mojolicious::Plugin::Skinir::Fields> for the constructors and the
distribution README for the complete list of modifiers.

=cut
