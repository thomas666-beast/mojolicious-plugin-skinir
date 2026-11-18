# Skinir 0.03 User Guide

Skinir turns Yggdrasil models into a Mojolicious admin panel. Start with one resource and a narrow admin gate. Add write permissions, actions, and metrics only where your team needs them.

If you do not have a Mojolicious application yet, follow [Build Your First Skinir App](Build-Your-First-Skinir-App.md) instead.

## Run the SQLite demo

The release bundle contains the Skinir distribution, the matching Yggdrasil distributions, and the FormRequest, Policy, and Translatable companion distributions. Run these commands from the extracted bundle directory. You need Perl 5.20 or newer, `cpanm`, and a build toolchain for dependencies with native extensions.

```bash
cpanm -L "$PWD/local" \
  ./Yggdrasil-0.05.tar.gz \
  ./Mojolicious-Plugin-Yggdrasil-0.04.tar.gz \
  ./Mojolicious-Plugin-FormRequest-0.01.tar.gz \
  ./Mojolicious-Plugin-Policy-0.01.tar.gz \
  ./Mojolicious-Plugin-Translatable-0.01.tar.gz \
  DBD::SQLite \
  ./Mojolicious-Plugin-Skinir-0.03.tar.gz

export PERL5LIB="$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"
tar -xzf Mojolicious-Plugin-Skinir-0.03.tar.gz
cd Mojolicious-Plugin-Skinir-0.03
perl examples/skinir-demo daemon -l http://127.0.0.1:3000
```

Open [the local demo](http://127.0.0.1:3000/admin). Demo accounts all use `demo-only-passphrase`; the databases are temporary and reset when you restart the app. Do not expose the demo to a network or reuse its credentials.

| Account | What to try |
|---|---|
| `operator@example.test` | Open Tickets, filter by status and click **Export CSV**. Create a ticket, use **Close selected**, then delete it to move it to the trash and restore it. |
| `viewer@example.test` | Open the same lists and details without write permission. |
| `customer@example.test` | Confirm that a known account without panel access cannot sign in. |

The demo uses separate `accounts` and `workspace` SQLite connections and `legacy_global => 0`. The app, schema, sample data, models, policies, and resources are all in `examples/lib/SkinirDemo.pm`. No Node.js build is needed to run Skinir.

## Add Skinir to your app

In `startup`, load Yggdrasil, then Skinir. This example assumes a `db/app.db` database with `MyApp::Model::User` and `MyApp::Model::Post` already mapped. Create or migrate the tables using your application's normal migration workflow; Skinir does not change the schema.

```perl
$self->plugin(Yggdrasil => {
  driver => 'sqlite',
  database => 'db/app.db',
  models => 'MyApp::Model',
  legacy_global => 0,
});

$self->plugin(Skinir => {
  name => 'Content Admin',
  path => '/admin',
  user_model => 'User',
  gate => sub {
    my ($c, $user) = @_;
    return ($user->get_attribute('role') // '') eq 'admin';
  },
  resources => ['MyApp::Resource::Post'],
});
```

The default sign-in columns are `email`, `password`, and `name`. Store a password hash, not the original password. If your application has the right schema, `perl script/my_app skinir make:user admin@example.test "Admin"` creates an account; your app must assign the role or capability the gate checks. `user_connection` binds login and user creation to a named connection.

## Define the first resource

Create `lib/MyApp/Resource/Post.pm`. List the fields you actually want to expose. A field used only for display should normally be marked `readonly`.

```perl
package MyApp::Resource::Post;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Resource', -signatures;
use Mojolicious::Plugin::Skinir::Fields qw(ID Text Select);
use Mojolicious::Plugin::Skinir::Filter qw(SelectFilter);

sub model    { 'Post' }
sub uri_key  { 'posts' }
sub title    { 'title' }
sub search   { ['title'] }
sub per_page { 25 }

sub fields ($self, $c) {[
  ID(),
  Text('Title')->sortable->required->rules('max:150'),
  Select('Status')->required->options({draft => 'Draft', live => 'Live'}),
]}

sub filters ($self, $c) {[
  SelectFilter('Status', 'status', {draft => 'Draft', live => 'Live'}),
]}

1;
```

Visit `/admin/resources/posts`. The default policy exposes the list and detail to users who pass the gate but does not permit writes. Define a policy and set `sub policy { 'MyApp::Policy::Post' }` on the resource when you are ready to grant specific write abilities.

```perl
package MyApp::Policy::Post;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Policy', -signatures;

sub create ($self, $c, $post) {
  return !!$c->skinir_user->get_attribute('can_edit_posts');
}
sub update ($self, $c, $post) {
  return $self->create($c, $post);
}

1;
```

`view_any`, `create`, and standalone action abilities receive a blank, connection-bound model. `view`, `update`, `delete`, `restore`, and `force_delete` receive the stored row. Use `$c->skinir_user`, not the main site's `current_user`. If your app already loads Policy, register Skinir's model-policy mappings in that plugin configuration.

## Scope visibility in SQL

For tenant-owned data, put the rule in `scope_query`, not `index_query`. `scope_query` applies to listings, record lookups, mutations on existing rows, and resource-backed relationship and metric queries. Set ownership from trusted server-side state on creation. Do not make the tenant column editable.

```perl
sub scope_query ($self, $c, $q) {
  return $q->where(tenant_id => $c->skinir_user->get_attribute('tenant_id'));
}

sub before_save ($self, $c, $row, $mode) {
  $row->set_attribute(tenant_id => $c->skinir_user->get_attribute('tenant_id'))
    if $mode eq 'create';
}
```

Ensure the gate excludes users without a tenant for tenant-scoped resources. Add restrictions to the passed query, group any `OR` conditions, and do not replace the query with a new one. Keep a corresponding `view` policy for defense in depth.

Skinir uses SQL counts for pagination and metrics. It applies the Perl row policy before serializing records, so a policy stricter than the SQL scope can produce shorter pages while totals still count those rows. Put the full visibility rule in SQL if row existence or counts are sensitive.

## Relationships, actions, and files

- **Relationships**: `BelongsTo('Queue', 'queue_id', 'queues')` uses the registered `queues` resource for labels, choices, and validation. A reference you cannot view is not shown, and an existing hidden relation is omitted from the edit form rather than silently cleared. `HasMany('Tickets', 'tickets', 'tickets')->rows_limit(5)` uses a Yggdrasil `has_many` relation on the target resource's connection; the panel count is the number shown, not a database total.
- **Actions**: Use `actions($c)` to declare `Mojolicious::Plugin::Skinir::Action` instances. A row action checks visibility and `update` for every selected row (`delete` for destructive actions), unless you set a different `ability`. A standalone action requires `run_action` by default, or a named ability you configure explicitly. Put multi-row writes in a transaction inside the handler if they must succeed or fail together.
- **Soft deletes**: Use `Yggdrasil::Role::SoftDeletes` and a nullable `deleted_at` column. Grant `restore` and `force_delete` separately. Permanent deletion requires a row already in the trash.
- **Metrics**: Use `ValueMetric('Visible posts', date_column => undef, ranges => [])` in a resource's `cards`. A dashboard card can pass `resource => 'posts'` to use that resource's scope and connection. Metrics declared directly against `model` are app-defined aggregates; set a SQL `filter` when different operators should see different totals.
- **Uploads**: The default `public/uploads` directory is public even if the containing row is protected. Use Skinir's `File` and `Image` fields only for files intended to be public. If you customize `uploads_dir` and `uploads_url`, configure your app or reverse proxy to serve the directory at that URL. For confidential files, implement private storage and an authorized download route in the host app. Size and extension checks do not scan file contents. Skinir cleans up new files when a save rolls back and removes old files after successful replacement or permanent deletion; a process or filesystem failure can still leave orphan files.

## Enable CSV export

Opt in on both the resource and its policy. Define `sub csv_columns ($self, $c) { [qw(id title status)] }` in the resource and `sub export ($self, $c, $row) { ... }` in the policy. The policy receives a blank bound model, like `create`; the existing `view` policy is also enforced for each exported row. An empty column list or a denied `export` ability leaves the button hidden.

The export uses the current search, sort, filters, trash selection, and row visibility, regardless of page or checkbox selection. Only declared index fields can be exported; password, file, image and has-many fields are excluded. A visible `BelongsTo` field exports its label, not its foreign key. The file is UTF-8 with a BOM, quotes cells, and prefixes formula-like values with an apostrophe to reduce spreadsheet formula evaluation risk. For example, signed numbers beginning with `-` are emitted as spreadsheet text.

The maximum is 5,000 query matches before applying the Perl row policy, or 5 MiB of output. Larger requests fail with a prompt to narrow the filters and do not return a partial file. The interactive export is not a database snapshot: edits made while it runs can affect which records are returned.

## Deploy and upgrade

- **Sessions**: Set stable, high-entropy Mojolicious secrets and secure cookie settings behind HTTPS. Skinir uses a separate user key and expiry inside the host's signed cookie, not a separate cookie or origin. Configure proxy-level rate limiting in production because the default login throttle is per process.
- **Vue assets**: Skinir loads a pinned Vue version from jsDelivr by default. For a host that should not contact a CDN, run `perl script/my_app skinir assets:vue`, then set `vue => 'local'`. The current Vue runtime template compiler needs CSP support for `'unsafe-eval'`; self-hosting alone does not remove that requirement.
- **Upgrade from 0.01**: Add `gate`, explicitly grant required writes, and have users sign in again. Move visibility restrictions from `index_query` to `scope_query`. A resource metric now defaults to its current resource; if a card should use a different resource, name it with `resource => 'other-resource'`. Confirm any pre-existing FormRequest DB resolver respects `$c->stash('skinir.connection')`.
- **Operational limits**: Lists use offset pagination with at most 100 rows per page, options return at most 50 matches plus an authorized current choice, and bulk calls accept at most 500 IDs. Use indexed scopes and sorts on large tables; broad text searches and deep offsets can still be expensive. REST resource IDs are scalar integers or URL-safe IDs with letters, digits, `_` and `-`. Compound primary keys are not supported.

For the complete field, filter, theme, translation, CLI and JSON API reference, see the README shipped with the distribution.
