package Mojolicious::Plugin::Skinir::Controller::Resources;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::Collection;
use Mojo::JSON qw(decode_json true);
use Mojo::Util qw(encode);
use Text::CSV 2.00;

use constant MAX_BULK => 500;
use constant CSV_BATCH => 100;
use constant CSV_MAX_ROWS => 5_000;
use constant CSV_MAX_BYTES => 5 * 1024 * 1024;

# ---- plumbing ------------------------------------------------------------------------
# Returns the resource and an unsaved, app-bound model.
sub _ctx ($c) {
  my $res = $c->skinir->resource($c->stash('resource'));
  unless ($res) { $c->render(json => {message => 'Unknown resource'}, status => 404); return }
  my $model = $c->skinir->record($res);
  unless ($c->allowed('view_any', $model)) { $c->_forbidden; return }
  $c->stash('skinir.connection' => $model->connection->name);
  $c->stash('skinir.resource_key' => $res->uri_key);
  return ($res, $model);
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

sub _find ($c, $res, $class, $id) {
  return undef unless $c->skinir->valid_id($class, $id);
  my $m = $c->skinir->query($c, $res, with_trashed => 1)->find($id);
  return $m && $c->allowed('view', $m) ? $m : undef;
}

sub _is_trashed ($class, $m) { $class->soft_deletes && $m->trashed ? 1 : 0 }

sub _ids ($c, $j, $model) {
  my $ids = $j->{ids};
  return undef unless ref $ids eq 'ARRAY' && @$ids && @$ids <= MAX_BULK;
  return undef if grep { !$c->skinir->valid_id($model, $_) } @$ids;
  my %seen;
  return [grep { !$seen{$_}++ } @$ids];
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
    can_create   => ($c->allowed('create', $class) ? \1 : \0),
    filters      => [map { $_->meta($c) } @{$res->filters($c)}],
    actions      => [map { $_->meta($c, $res) }
      grep { !$_->standalone || $c->allowed($_->required_ability, $class) } @{$res->actions($c)}],
    cards        => [map { $_->meta($c, $res->uri_key) } @{$res->cards($c)}],
  };
}

sub _form_fields ($c, $res, $mode) {
  return [grep { $_->shown_on($mode) && $_->type ne 'has_many' && !$_->computed } @{$res->fields($c)}];
}

sub _purge_files ($c, $res, $m) {
  for my $f (grep { $_->type =~ /\A(?:image|file)\z/ } @{$res->fields($c)}) {
    my $v = $m->get_attribute($f->attribute);
    push @{$c->stash->{'skinir.old_files'}}, $v if defined $v && length $v;
  }
}

# Shared by the index and CSV export, before pagination.
sub _index_query ($c, $res, $class, $fields) {
  my $pk     = $class->primary_key;

  my $trashed = $c->param('trashed') // '';
  return $c->_invalid({trashed => 'Use with or only'}) unless $trashed =~ /\A(?:with|only)?\z/;
  my $q = $c->skinir->query($c, $res, with_trashed => $trashed eq 'with', only_trashed => $trashed eq 'only');
  $q = $res->index_query($c, $q) // $q;
  $q->include(@{$res->eager}) if @{$res->eager};

  # filters: ?filters={"status":"draft"}
  my $raw = $c->param('filters');
  my $fv  = {};
  if (defined $raw && length $raw) {
    return $c->_invalid({filters => 'Filter input is too long'}) if length($raw) > 8192;
    $fv = eval { decode_json($raw) };
    return $c->_invalid({filters => 'Expected a JSON object'}) unless ref $fv eq 'HASH';
  }
  for my $f (@{$res->filters($c)}) {
    my $v = $fv->{$f->key};
    next unless defined $v && (ref $v || length $v);
    return $c->_invalid({filters => 'Invalid value for ' . $f->key}) unless $f->valid_input($v);
    $f->apply($c, $q, $v);
  }

  # search
  my $term = $c->param('search');
  return $c->_invalid({search => 'Maximum 200 characters'}) if length($term // '') > 200;
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
  return $q;
}

sub _csv_fields ($c, $res, $class, $fields) {
  return [] unless $c->allowed('export', $class);
  my %allowed;
  for my $f (@$fields) {
    next if $f->type =~ /\A(?:password|file|image|has_many)\z/;
    $allowed{$f->attribute} //= $f;
  }
  my %seen;
  return [map { $allowed{$_} } grep { exists $allowed{$_} && !$seen{$_}++ } @{$res->csv_columns($c)}];
}

# ---- index ----------------------------------------------------------------------------
sub index ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $s      = $c->skinir;
  my $fields = [grep { $_->shown_on('index') } @{$res->fields($c)}];
  my $q = $c->_index_query($res, $class, $fields) or return;

  my $per = $c->param('per_page');
  return $c->_invalid({per_page => 'Page size is not allowed'})
    if defined $per && ($per !~ /\A[1-9][0-9]{0,2}\z/
      || !grep { $_ == $per } ($res->per_page, @{$s->config->{per_page_options}}));
  $per //= $res->per_page;
  my $requested_page = $c->param('page') // 1;
  return $c->_invalid({page => 'Enter a page number from 1 to 100,000'})
    unless $requested_page =~ /\A(?:[1-9][0-9]{0,4}|100000)\z/;

  my $page  = $q->paginate($per, $requested_page);
  my $items = [grep { $c->allowed('view', $_) } @{$page->items}];
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
    resource => {%{$c->_resource_meta($res, $class)}, columns => [map { $_->meta($c, $res) } @$fields],
      can_export => (@{$c->_csv_fields($res, $class, $fields)} ? \1 : \0)},
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

sub _csv_line ($csv, @cells) {
  for my $cell (@cells) {
    $cell //= '';
    # Quoting alone does not prevent spreadsheet formula evaluation.
    $cell = "'$cell" if $cell =~ /\A(?:[\t\r\n]|[\p{Space}\p{Cc}\p{Cf}]*[=+\-@\x{ff1d}\x{ff0b}\x{ff0d}\x{ff20}])/;
  }
  $csv->combine(@cells) or die "Skinir: unable to encode a CSV row\n";
  return encode('UTF-8', $csv->string);
}

sub _csv_value ($c, $f, $model) {
  my $v = $f->display($c, $model);
  return undef unless defined $v;
  return (ref $v ? $$v : $v) ? 1 : 0 if $f->type eq 'boolean';
  return ref $v eq 'HASH' ? $v->{title} : undef if $f->type eq 'belongs_to';
  return ref $v ? undef : $v;
}

sub _csv_limit ($c) {
  return $c->render(status => 422, json => {message => $c->skinir->t($c, 'csv_too_large')});
}

sub export_csv ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $fields = [grep { $_->shown_on('index') } @{$res->fields($c)}];
  my $columns = $c->_csv_fields($res, $class, $fields);
  return $c->_forbidden unless @$columns;
  my $q = $c->_index_query($res, $class, $fields) or return;
  my $csv = Text::CSV->new({binary => 1, eol => "\r\n", always_quote => 1});
  my $out = "\xef\xbb\xbf" . _csv_line($csv, map { $c->skinir->field_label($c, $res, $_) } @$columns);
  return $c->_csv_limit if length($out) > CSV_MAX_BYTES;
  my $offset = 0;
  while (1) {
    my $limit = $offset == CSV_MAX_ROWS ? 1 : CSV_BATCH;
    my $rows = $q->clone->limit($limit)->offset($offset)->get;
    return $c->_csv_limit if $offset + @$rows > CSV_MAX_ROWS;
    my @visible = grep { $c->allowed('view', $_) } @$rows;
    $_->prefetch($c, \@visible) for @$columns;
    for my $model (@visible) {
      $out .= _csv_line($csv, map { $c->_csv_value($_, $model) } @$columns);
      return $c->_csv_limit if length($out) > CSV_MAX_BYTES;
    }
    last if @$rows < $limit;
    $offset += @$rows;
  }
  my $headers = $c->res->headers;
  $headers->content_type('text/csv; charset=UTF-8');
  $headers->content_disposition('attachment; filename="' . $res->uri_key . '.csv"');
  $headers->header('X-Content-Type-Options' => 'nosniff');
  return $c->render(data => $out);
}

# ---- detail ---------------------------------------------------------------------------
sub show ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $c->_find($res, $class, $c->stash('id')) or return $c->_not_found;

  my @fields = grep { $_->shown_on('detail') } @{$res->fields($c)};
  $_->prefetch($c, [$m]) for @fields;

  my (@rows, @panels);
  for my $f (@fields) {
    if ($f->type eq 'has_many') {
      my $rres = $f->related_resource($c) or next;
      next unless $c->allowed('view_any', $c->skinir->record($rres));
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
  my $fields = $c->_editable_fields($res, $model, $mode);
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

sub _editable_fields ($c, $res, $model, $mode) {
  my $fields = $c->_form_fields($res, $mode);
  return $fields unless $model->in_storage;
  $_->prefetch($c, [$model]) for grep { $_->type eq 'belongs_to' } @$fields;
  return [grep {
    $_->type ne 'belongs_to' || !defined($_->raw($c, $model)) || $_->raw($c, $model) eq '' || $_->display($c, $model)
  } @$fields];
}

sub creation_fields ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $class;
  return $c->_forbidden unless $c->allowed('create', $m);
  $c->render(json => $c->_form_payload($res, $class, $m, 'create'));
}

sub update_fields ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $c->_find($res, $class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless !_is_trashed($class, $m) && $c->allowed('update', $m);
  $c->render(json => $c->_form_payload($res, $class, $m, 'update'));
}

# Validate, fill and persist. Renders the error response and returns undef on failure.
sub _save ($c, $res, $class, $model, $mode) {
  return $c->_invalid({body => 'Expected a JSON object'})
    if ($c->req->headers->content_type // '') =~ m{\Aapplication/json\b}i && ref($c->req->json) ne 'HASH';
  my @fields = grep { $_->is_fillable } @{$c->_editable_fields($res, $model, $mode)};
  my $input_errors = $c->_input_errors(\@fields, $mode);
  return $c->_invalid($input_errors) if %$input_errors;
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
  my $err = $@;
  $c->_cleanup_uploads($ok ? 'old' : 'new');
  return $c->_failed("$mode " . $res->uri_key, $err) unless $ok;
  return $model;
}

sub store ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $class;
  return $c->_forbidden unless $c->allowed('create', $m);
  my $saved = $c->_save($res, $class, $m, 'create') or return;
  $c->render(json => {id => $saved->get_key, title => $res->title_of($saved)}, status => 201);
}

sub update ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $c->_find($res, $class, $c->stash('id')) or return $c->_not_found;
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

sub _cleanup_uploads ($c, $which) {
  $c->skinir->delete_upload($_) for @{delete($c->stash->{"skinir.${which}_files"}) // []};
}

sub _input_errors ($c, $fields, $mode) {
  my $json = $c->req->json;
  my $params = $c->req->params->to_hash;
  my %errors;
  for my $f (@$fields) {
    next if $f->type =~ /\A(?:image|file)\z/;
    my $attr = $f->attribute;
    my $v = ref $json eq 'HASH' && exists $json->{$attr} ? $json->{$attr} : $params->{$attr};
    if (ref $v && !($f->type eq 'boolean' && ref($v) eq ref(true))) {
      $errors{$attr} = 'Expected a scalar value';
    }
    elsif ($f->type eq 'password' && length($v // '') > 1024) {
      $errors{$attr} = 'Maximum 1024 characters';
    }
    elsif ($f->_declares_required($mode) && (!defined $v || (!ref $v && $v !~ /\S/))) {
      $errors{$attr} = 'is required';
    }
  }
  return \%errors;
}

sub destroy ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $m = $c->_find($res, $class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless !_is_trashed($class, $m) && $c->allowed('delete', $m);
  my $ok = eval { $class->connection->transaction(sub { $c->_delete_one($res, $class, $m, 0) }); 1 };
  return $c->_failed('delete ' . $res->uri_key, $@) unless $ok;
  $c->_cleanup_uploads('old');
  $c->render(json => {ok => \1});
}

sub force_delete ($c) {
  my ($res, $class) = $c->_ctx or return;
  return $c->_not_found unless $class->soft_deletes;
  my $m = $c->_find($res, $class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless _is_trashed($class, $m) && $c->allowed('force_delete', $m);
  my $ok = eval { $class->connection->transaction(sub { $c->_delete_one($res, $class, $m, 1) }); 1 };
  return $c->_failed('force delete ' . $res->uri_key, $@) unless $ok;
  $c->_cleanup_uploads('old');
  $c->render(json => {ok => \1});
}

sub restore ($c) {
  my ($res, $class) = $c->_ctx or return;
  return $c->_not_found unless $class->soft_deletes;
  my $m = $c->_find($res, $class, $c->stash('id')) or return $c->_not_found;
  return $c->_forbidden unless _is_trashed($class, $m) && $c->allowed('restore', $m);
  my $ok = eval { $m->restore; 1 };
  return $c->_failed('restore ' . $res->uri_key, $@) unless $ok;
  $c->render(json => {ok => \1});
}

sub bulk ($c) {
  my ($res, $class) = $c->_ctx or return;
  my $j  = $c->req->json;
  return $c->_invalid({body => 'Expected a JSON object'}) unless ref $j eq 'HASH';
  my $op = $j->{op} // '';
  return $c->render(json => {message => 'Unknown operation'}, status => 422)
    unless !ref($op) && $op =~ /\A(?:delete|restore|force_delete)\z/;
  return $c->_not_found if $op ne 'delete' && !$class->soft_deletes;

  my $ids = $c->_ids($j, $class) // return $c->_invalid({ids => 'Select 1 to 500 valid records'});

  my ($done, $skipped) = (0, scalar @$ids);
  my $ok = eval {
    $class->connection->transaction(sub {
      my $models = $c->skinir->query($c, $res, with_trashed => 1)->where_in($class->primary_key, $ids)->get;
      for my $m (@$models) {
        next unless $c->allowed('view', $m);
        my $t = _is_trashed($class, $m);
        my $allowed = $op eq 'delete'  ? (!$t && $c->allowed('delete', $m))
                    : $op eq 'restore' ? ($t  && $c->allowed('restore', $m))
                    :                   ($t && $c->allowed('force_delete', $m));
        next unless $allowed;
        if    ($op eq 'restore') { $m->restore }
        else                     { $c->_delete_one($res, $class, $m, $op eq 'force_delete') }
        $done++;
        $skipped--;
      }
    });
    1;
  };
  return $c->_failed("bulk $op " . $res->uri_key, $@) unless $ok;
  $c->_cleanup_uploads('old');
  $c->render(json => {ok => \1, processed => $done, skipped => $skipped});
}

# ---- custom actions ---------------------------------------------------------------------
sub run_action ($c) {
  my ($res, $class) = $c->_ctx or return;
  my ($action) = grep { $_->key eq $c->stash('action_key') } @{$res->actions($c)};
  return $c->_not_found unless $action;
  my $j = $c->req->json;
  return $c->_invalid({body => 'Expected a JSON object'}) unless ref $j eq 'HASH';

  my $models = Mojo::Collection->new;
  unless ($action->standalone) {
    my $ids = $c->_ids($j, $class) // return $c->_invalid({ids => 'Select 1 to 500 valid records'});
    $models = $c->skinir->query($c, $res)->where_in($class->primary_key, $ids)->get;
    return $c->_not_found unless @$models == @$ids;
    my $ability = $action->required_ability;
    for my $m (@$models) {
      return $c->_not_found unless $c->allowed('view', $m);
      return $c->_forbidden unless $c->allowed($ability, $m);
    }
  }
  else {
    return $c->_forbidden unless $c->allowed($action->required_ability, $class);
  }

  # action fields are sent next to "ids" in the JSON body
  my %rules;
  my @fields = grep { $_->is_fillable } @{$action->field_list($c)};
  my $input_errors = $c->_input_errors(\@fields, 'create');
  return $c->_invalid($input_errors) if %$input_errors;
  for my $f (@fields) {
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
  my $rcls = $c->skinir->record($rres);
  return $c->_forbidden unless $c->allowed('view_any', $rcls);

  my $pk    = $rcls->primary_key;
  my $title = $rres->title;
  my $col   = !ref $title && $title ne $pk ? $title : undef;
  my $q     = $c->skinir->query($c, $rres);

  my $term = $c->param('search');
  return $c->_invalid({search => 'Maximum 200 characters'}) if length($term // '') > 200;
  if (defined $term && length $term) {
    my @cols = @{$rres->search} ? @{$rres->search} : ($col // ());
    $q->where(sub ($w) { $w->or_where($_, 'ilike', "%$term%") for @cols }) if @cols;
  }
  $q->order_by($col // $pk, 'asc')->limit(50);

  my @items = map { +{value => $_->get_key, label => $rres->title_of($_)} }
    grep { $c->allowed('view', $_) } @{$q->get};

  my $cur = $c->param('current');
  if (defined $cur && length $cur && !grep { $_->{value} eq $cur } @items) {
    if ($c->skinir->valid_id($rcls, $cur)) {
      my $m = $c->skinir->query($c, $rres)->find($cur);
      unshift @items, {value => $m->get_key, label => $rres->title_of($m)} if $m && $c->allowed('view', $m);
    }
  }
  $c->render(json => {data => \@items});
}

1;
