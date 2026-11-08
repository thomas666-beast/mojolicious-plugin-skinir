package Mojolicious::Plugin::Skinir::Controller::Resources;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::Collection;
use Mojo::JSON qw(decode_json);

use constant MAX_BULK => 500;

# ---- plumbing ------------------------------------------------------------------------
# Returns ($resource, $model_class), or renders a 404 and returns an empty list.
sub _ctx ($c) {
  my $res = $c->skinir->resource($c->stash('resource'));
  unless ($res) { $c->render(json => {message => 'Unknown resource'}, status => 404); return }
  $c->stash('skinir.connection' => $res->connection);
  $c->stash('skinir.resource_key' => $res->uri_key);
  return ($res, $c->model($res->model));
}

sub _forbidden ($c) { $c->render(json => {message => 'This action is unauthorized.'}, status => 403); return undef }
sub _not_found ($c) { $c->render(json => {message => 'Not found'}, status => 404); return undef }

sub _invalid ($c, $errors) {
  my %e = map { ($_ => (ref $errors->{$_} eq 'ARRAY' ? $errors->{$_} : [$errors->{$_}])) } keys %$errors;
  $c->render(json => {message => 'The given data was invalid.', errors => \%e}, status => 422);
  return undef;
}

sub _failed ($c, $what, $err) {
  $c->app->log->error("Skinir: $what failed: $err");
  my %body = (message => $c->skinir->t($c, 'error_generic'));
  $body{detail} = "$err" if $c->app->mode eq 'development';
  $c->render(json => \%body, status => 500);
  return undef;
}

sub _find ($c, $class, $id) {
  return undef unless defined $id && length $id && $id !~ m{[/\\]};
  return undef if $class->incrementing && $id !~ /\A\d+\z/;
  return $class->query(with_trashed => 1)->find($id);
}

sub _is_trashed ($class, $m) { $class->soft_deletes && $m->trashed ? 1 : 0 }

sub _ids ($c) {
  my $j   = $c->req->json;
  my $ids = ref $j eq 'HASH' && ref $j->{ids} eq 'ARRAY' ? $j->{ids} : [];
  my %seen;
  my @ok = grep { defined $_ && !ref $_ && /\A[\w-]{1,64}\z/ && !$seen{$_}++ } @$ids;
  splice @ok, MAX_BULK if @ok > MAX_BULK;
  return @ok;
}

sub _abilities ($c, $class, $m) {
  my $trashed = _is_trashed($class, $m);
  my %a = (
    view         => $c->allowed('view', $m) ? \1 : \0,
    update       => (!$trashed && $c->allowed('update', $m)) ? \1 : \0,
    delete       => (!$trashed && $c->allowed('delete', $m)) ? \1 : \0,
    restore      => ($trashed && $c->allowed('restore', $m)) ? \1 : \0,
    force_delete => ($trashed && $c->allowed('force_delete', $m)) ? \1 : \0,
  );
  return \%a;
}

sub _resource_meta ($c, $res, $class) {
  my $s = $c->skinir;
  return {
    key          => $res->uri_key,
    label        => $s->resource_label($c, $res),
    singular     => $s->resource_singular($c, $res),
    soft_deletes => ($class->soft_deletes ? \1 : \0),
    searchable   => (@{$res->search} ? \1 : \0),
    per_page     => $res->per_page,
    can_create   => ($c->allowed('create', $class->new) ? \1 : \0),
    filters      => [map { $_->meta($c) } @{$res->filters($c)}],
    actions      => [map { $_->meta($c, $res) } @{$res->actions($c)}],
    cards        => [map { $_->meta($c, $res->uri_key) } @{$res->cards($c)}],
  };
}

sub _form_fields ($c, $res, $mode) {
  return [grep { $_->shown_on($mode) && $_->type ne 'has_many' && !$_->computed } @{$res->fields($c)}];
}

sub _purge_files ($c, $res, $m) {
  for my $f (grep { $_->type =~ /\A(?:image|file)\z/ } @{$res->fields($c)}) {
    my $v = $m->get_attribute($f->attribute);
    $c->skinir->delete_upload($v) if defined $v && length $v;
  }
}

# ---- index ----------------------------------------------------------------------------
sub index ($c) {
  my ($res, $class) = $c->_ctx or return;
  return $c->_forbidden unless $c->allowed('view_any', $class->new);

  my $s      = $c->skinir;
  my $fields = [grep { $_->shown_on('index') } @{$res->fields($c)}];
  my $pk     = $class->primary_key;

  my $trashed = $c->param('trashed') // '';
  my $q = !$class->soft_deletes ? $class->query
        : $trashed eq 'only'    ? $class->only_trashed
        : $trashed eq 'with'    ? $class->query(with_trashed => 1)
        :                         $class->query;
  $q = $res->index_query($c, $q) // $q;
  $q->include(@{$res->eager}) if @{$res->eager};

  # filters: ?filters={"status":"draft"}
  my $raw = $c->param('filters');
  my $fv  = {};
  if (defined $raw && length $raw) {
    $fv = eval { decode_json($raw) };
    $fv = {} unless ref $fv eq 'HASH';
  }
  for my $f (@{$res->filters($c)}) {
    my $v = $fv->{$f->key};
    next unless defined $v && (ref $v || length $v);
    $f->apply($c, $q, $v);
  }

  # search
  my $term = $c->param('search');
  if (defined $term && length $term && @{$res->search}) {
    my @cols = @{$res->search};
    $q->where(sub ($w) { $w->or_where($_, 'ilike', "%$term%") for @cols });
  }

  # sort (whitelisted to sortable index columns)
  my %sortable = map { ($_->attribute => 1) } grep { $_->is_sortable && !$_->computed } @$fields;
  my $by  = $c->param('order_by');
  my $dir = lc($c->param('order_dir') // 'asc') eq 'desc' ? 'desc' : 'asc';
  if (defined $by && $sortable{$by}) {
    $q->order_by($by, $dir);
    $q->order_by($pk, 'desc') unless $by eq $pk;
  }
  else {
    my $order = $res->order // [[$pk, 'desc']];
    $q->order_by(@$_) for @$order;
    $q->order_by($pk, 'desc') unless grep { $_->[0] eq $pk } @$order;   # stable paging
  }

  my $per = $c->param('per_page');
  $per = $res->per_page unless defined $per && $per =~ /\A\d+\z/ && grep { $_ == $per } @{$s->config->{per_page_options}};

  my $page  = $q->paginate($per, scalar $c->param('page'));
  my $items = $page->items;
  $_->prefetch($c, $items) for @$fields;

  my @data = map {
    my $m = $_;
    +{
      id        => $m->get_key,
      title     => $res->title_of($m),
      trashed   => (_is_trashed($class, $m) ? \1 : \0),
      fields    => {map { ($_->attribute => $_->display($c, $m)) } @$fields},
      abilities => $c->_abilities($class, $m),
    }
  } @$items;

  $c->render(json => {
    resource => {%{$c->_resource_meta($res, $class)}, columns => [map { $_->meta($c, $res) } @$fields]},
    data     => \@data,
    meta     => {
      total        => $page->total,
      per_page     => $page->per_page,
      current_page => $page->current_page,
      last_page    => $page->last_page,
      from         => $page->from,
      to           => $page->to,
    },
  });
}

# ---- detail ---------------------------------------------------------------------------
sub show ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $c->_find($class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless $c->allowed('view', $m);

  my @fields = grep { $_->shown_on('detail') } @{$res->fields($c)};
  $_->prefetch($c, [$m]) for @fields;

  my (@rows, @panels);
  for my $f (@fields) {
    if ($f->type eq 'has_many') {
      my $rres = $f->related_resource($c) or next;
      next unless $c->allowed('view_any', $c->model($rres->model)->new);
      my $p = $f->panel($c, $m) or next;
      $p->{label} = $c->skinir->field_label($c, $res, $f);
      push @panels, $p;
      next;
    }
    push @rows, {%{$f->meta($c, $res)}, value => $f->display($c, $m)};
  }

  $c->render(json => {
    resource  => $c->_resource_meta($res, $class),
    id        => $m->get_key,
    title     => $res->title_of($m),
    trashed   => (_is_trashed($class, $m) ? \1 : \0),
    fields    => \@rows,
    panels    => \@panels,
    abilities => $c->_abilities($class, $m),
  });
}

# ---- forms ----------------------------------------------------------------------------
sub _form_payload ($c, $res, $class, $model, $mode) {
  my @out;
  my $fields = $c->_form_fields($res, $mode);
  $_->prefetch($c, [$model]) for grep { $_->type eq 'belongs_to' } @$fields;
  for my $f (@$fields) {
    my %m = (%{$f->meta($c, $res)}, value => $f->form_value($c, $model));
    $m{current} = $f->display($c, $model) if $f->type eq 'belongs_to' && $model->in_storage;
    push @out, \%m;
  }
  return {
    resource => $c->_resource_meta($res, $class),
    id       => ($model->in_storage ? $model->get_key : undef),
    title    => ($model->in_storage ? $res->title_of($model) : undef),
    fields   => \@out,
  };
}

sub creation_fields ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $class->new;
  return $c->_forbidden unless $c->allowed('create', $m);
  $c->render(json => $c->_form_payload($res, $class, $m, 'create'));
}

sub update_fields ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $c->_find($class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless !_is_trashed($class, $m) && $c->allowed('update', $m);
  $c->render(json => $c->_form_payload($res, $class, $m, 'update'));
}

# Validate, fill and persist. Renders the error response and returns undef on failure.
sub _save ($c, $res, $class, $model, $mode) {
  my @fields = grep { $_->is_fillable } @{$c->_form_fields($res, $mode)};
  my $id     = $mode eq 'update' ? $model->get_key : undef;

  my %rules;
  for my $f (@fields) {
    my $r = $f->compile_rules($c, $mode, $class, $id);
    $rules{$f->attribute} = $r if defined $r;
  }

  my $result = $c->form_request('Mojolicious::Plugin::FormRequest::Base')->inline_rules(\%rules)->validate;
  my %errors = %{$result->{ok} ? {} : ($result->{errors} // {})};
  for my $f (grep { $_->type =~ /\A(?:image|file)\z/ } @fields) {
    my $e = $f->check_upload($c, $mode);
    $errors{$f->attribute} = [$e] if defined $e;
  }
  return $c->_invalid(\%errors) if %errors;

  my $data = $result->{data} // {};
  my $ok = eval {
    $class->connection->transaction(sub {
      $_->fill($c, $model, $data) for @fields;
      $res->before_save($c, $model, $mode);
      $model->save;
      $res->after_save($c, $model, $mode);
    });
    1;
  };
  return $c->_failed("$mode " . $res->uri_key, $@) unless $ok;
  return $model;
}

sub store ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $class->new;
  return $c->_forbidden unless $c->allowed('create', $m);
  my $saved = $c->_save($res, $class, $m, 'create') or return;
  $c->render(json => {id => $saved->get_key, title => $res->title_of($saved)}, status => 201);
}

sub update ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $c->_find($class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless !_is_trashed($class, $m) && $c->allowed('update', $m);
  my $saved = $c->_save($res, $class, $m, 'update') or return;
  $c->render(json => {id => $saved->get_key, title => $res->title_of($saved)});
}

# ---- delete / restore -----------------------------------------------------------------
sub _delete_one ($c, $res, $class, $m, $force) {
  $res->before_delete($c, $m);
  my $hard = $force || !$class->soft_deletes;
  $force ? $m->force_delete : $m->delete;
  $c->_purge_files($res, $m) if $hard;
  $res->after_delete($c, $m);
}

sub destroy ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $c->_find($class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless !_is_trashed($class, $m) && $c->allowed('delete', $m);
  my $ok = eval { $class->connection->transaction(sub { $c->_delete_one($res, $class, $m, 0) }); 1 };
  return $c->_failed('delete ' . $res->uri_key, $@) unless $ok;
  $c->render(json => {ok => \1});
}

sub force_delete ($c) {
  my ($res, $class) = $c->_ctx or return;
  return $c->_not_found unless $class->soft_deletes;
  my $m = $c->_find($class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless $c->allowed('force_delete', $m);
  my $ok = eval { $class->connection->transaction(sub { $c->_delete_one($res, $class, $m, 1) }); 1 };
  return $c->_failed('force delete ' . $res->uri_key, $@) unless $ok;
  $c->render(json => {ok => \1});
}

sub restore ($c) {
  my ($res, $class) = $c->_ctx or return;
  return $c->_not_found unless $class->soft_deletes;
  my $m = $c->_find($class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless _is_trashed($class, $m) && $c->allowed('restore', $m);
  my $ok = eval { $m->restore; 1 };
  return $c->_failed('restore ' . $res->uri_key, $@) unless $ok;
  $c->render(json => {ok => \1});
}

sub bulk ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $j  = $c->req->json // {};
  my $op = $j->{op} // '';
  return $c->render(json => {message => 'Unknown operation'}, status => 422)
    unless $op =~ /\A(?:delete|restore|force_delete)\z/;
  return $c->_not_found if $op ne 'delete' && !$class->soft_deletes;

  my @ids = $c->_ids;
  return $c->render(json => {message => 'Nothing selected'}, status => 422) unless @ids;
  my $models = $class->query(with_trashed => 1)->where_in($class->primary_key, \@ids)->get;

  my ($done, $skipped) = (0, 0);
  my $ok = eval {
    $class->connection->transaction(sub {
      for my $m (@$models) {
        my $t = _is_trashed($class, $m);
        my $allowed = $op eq 'delete'  ? (!$t && $c->allowed('delete', $m))
                    : $op eq 'restore' ? ($t  && $c->allowed('restore', $m))
                    :                    $c->allowed('force_delete', $m);
        unless ($allowed) { $skipped++; next }
        if    ($op eq 'restore') { $m->restore }
        else                     { $c->_delete_one($res, $class, $m, $op eq 'force_delete') }
        $done++;
      }
    });
    1;
  };
  return $c->_failed("bulk $op " . $res->uri_key, $@) unless $ok;
  $skipped += @ids - @$models;
  $c->render(json => {ok => \1, processed => $done, skipped => $skipped});
}

# ---- custom actions ---------------------------------------------------------------------
sub run_action ($c) {
  my ($res, $class) = $c->_ctx or return;
  my ($action) = grep { $_->key eq $c->stash('action') } @{$res->actions($c)};
  return $c->_not_found unless $action;

  my $models = Mojo::Collection->new;
  unless ($action->standalone) {
    my @ids = $c->_ids;
    return $c->render(json => {message => 'Nothing selected'}, status => 422) unless @ids;
    $models = $class->query->where_in($class->primary_key, \@ids)->get;
    return $c->render(json => {message => 'Nothing selected'}, status => 422) unless @$models;
    my $ability = $action->required_ability;
    for my $m (@$models) { return $c->_forbidden unless $c->allowed($ability, $m) }
  }
  else {
    return $c->_forbidden unless $c->allowed('view_any', $class->new);
  }

  # action fields are sent next to "ids" in the JSON body
  my %rules;
  for my $f (grep { $_->is_fillable } @{$action->field_list($c)}) {
    my $r = $f->compile_rules($c, 'create', $class);
    $rules{$f->attribute} = $r if defined $r;
  }
  my $v = $c->form_request('Mojolicious::Plugin::FormRequest::Base')->inline_rules(\%rules)->validate;
  return $c->_invalid($v->{errors} // {}) unless $v->{ok};

  my $out;
  my $ok = eval { $out = $action->handle($c, $models, $v->{data}); 1 };
  return $c->_failed('action ' . $action->key, $@) unless $ok;
  return if $c->stash('mojo.rendered');                              # handler rendered itself

  $out = {} unless ref $out eq 'HASH';
  $c->render(json => {
    type     => $out->{type} // 'success',
    message  => $out->{message} // $c->skinir->t($c, 'action_done'),
    redirect => $out->{redirect},
  });
}

# ---- belongs_to option lists --------------------------------------------------------------
sub options ($c) {
  my ($res) = $c->_ctx or return;
  my ($f) = grep { $_->attribute eq $c->stash('attribute') && $_->type eq 'belongs_to' } @{$res->fields($c)};
  return $c->_not_found unless $f;
  my $rres = $f->related_resource($c) or return $c->_not_found;
  my $rcls = $c->model($rres->model);
  return $c->_forbidden unless $c->allowed('view_any', $rcls->new);

  my $pk    = $rcls->primary_key;
  my $title = $rres->title;
  my $col   = !ref $title && $title ne $pk ? $title : undef;
  my $q     = $rcls->query;

  my $term = $c->param('search');
  if (defined $term && length $term) {
    my @cols = @{$rres->search} ? @{$rres->search} : ($col // ());
    $q->where(sub ($w) { $w->or_where($_, 'ilike', "%$term%") for @cols }) if @cols;
  }
  $q->order_by($col // $pk, 'asc')->limit(50);

  my @items = map { +{value => $_->get_key, label => $rres->title_of($_)} } @{$q->get};

  my $cur = $c->param('current');
  if (defined $cur && length $cur && !grep { $_->{value} eq $cur } @items) {
    if (my $m = $c->_find($rcls, $cur)) { unshift @items, {value => $m->get_key, label => $rres->title_of($m)} }
  }
  $c->render(json => {data => \@items});
}

1;
