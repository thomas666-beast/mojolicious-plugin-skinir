# Mojolicious::Plugin::Skinir

A Nova-style admin panel for Mojolicious. You describe **resources**; Skinir gives you list / detail / create /
edit screens, search, filters, sorting, pagination, soft-delete handling, bulk and custom **actions**, dashboard
**metrics**, per-row **authorization**, validation, i18n and dark mode — as a Vue 3 + Tailwind CSS 4 client.

It builds on Yggdrasil (models, SQLite/PostgreSQL/MariaDB), FormRequest (validation), Policy (authorization),
Heimdall (auth/hashing) and Translatable (i18n). Load Yggdrasil first; Skinir loads the others if they are not
loaded yet.

```perl
$app->plugin(Yggdrasil => {...});
$app->plugin(Skinir => { namespace => 'MyApp::Resource', name => 'Admin' });
```

## Configuration

| option | default | |
|---|---|---|
| `path` | `/admin` | mount point |
| `name`, `logo` | `Skinir`, – | title / logo URL |
| `namespace` / `resources` | `<App>::Resource` / – | auto-discover classes, or give an explicit list |
| `user_model` | `User` | model that signs in |
| `login_field`, `password_field`, `name_field` | `email`, `password`, `name` | user columns |
| `gate` | allow all | `sub ($c, $user)`: may this user enter the panel at all? |
| `cards` | – | dashboard metrics: arrayref or `sub ($c)` |
| `policies` | `{}` | extra `ModelName => PolicyClass` for Policy |
| `locales`, `default_locale` | `[en fr]`, `en` | |
| `per_page_options` | `[10 25 50 100]` | allowed page sizes |
| `session_key`, `session_expires` | `skinir_uid`, 8 h | separate from your site's login session |
| `login_attempts`, `login_window` | 5, 900 s | per-IP throttle (in-process; add a proxy rate limit for multi-process setups) |
| `uploads_dir`, `uploads_url` | `public/uploads`, `/uploads` | where `Image` / `File` fields store files |
| `vue` | jsDelivr, Vue 3.5.13 | URL of Vue, or `'local'` → `/skinir/vendor/vue.global.prod.js` (`skinir assets:vue` downloads it) |
| `scripts`, `styles` | `[]` | extra JS / CSS to include (custom fields, theme overrides) |

## Resources

```perl
package MyApp::Resource::Post;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Resource', -signatures;
use Mojolicious::Plugin::Skinir::Fields;

sub model  { 'Post' }                    # required: Yggdrasil model name
sub title  { 'title' }                   # column (or coderef) used as the row title
sub search { [qw(title body)] }          # ILIKE columns for the search box
sub group  { 'Content' }                 # sidebar group
sub icon   { 'document' }                # see icon list below
sub policy { 'MyApp::Policy::Post' }
sub order  { [['created_at', 'desc']] }
sub eager  { ['author'] }                # include() on the index query

sub fields ($self, $c) {[ ID(), Text('Title')->sortable->rules('required|max:150') ]}
sub filters ($self, $c) {[ ... ]}
sub actions ($self, $c) {[ ... ]}
sub cards   ($self, $c) {[ ... ]}        # metrics shown above the index

# hooks
sub index_query  ($self, $c, $q)            { $q->where(tenant_id => ...) }   # scope what is listed
sub before_save  ($self, $c, $model, $mode) { }                               # $mode: create|update
sub after_save   ($self, $c, $model, $mode) { }
sub before_delete($self, $c, $model)        { }
sub after_delete ($self, $c, $model)        { }
```

Keys: the resource class `BlogPost` becomes `blog-posts` in URLs. Icons: `home collection document users user tag cog plus trash pencil eye search x check star bookmark inbox key lock mail shield chart calendar bolt folder image globe upload filter`.

## Fields

`ID Text Textarea Number Boolean Select Date DateTime Email Url Password Color Code Badge BelongsTo HasMany Image File`

`Text('Full name')` → attribute `full_name`; `Text('Full name', 'name')` picks the column.

| modifier | |
|---|---|
| `sortable`, `readonly`, `nullable`, `required`, `searchable` (BelongsTo) | flags |
| `rules('required\|max:255')`, `creation_rules(...)`, `update_rules(...)` | FormRequest rules (strings or coderefs) |
| `unique` / `unique($table, $col)` | ignores the row being edited |
| `help`, `placeholder`, `default` (value or `sub ($c)`), `prefix`, `suffix` | UI |
| `options({k => 'Label'})` / `[...]` / `sub ($c)` | Select (the value is validated against the list) |
| `types({v => 'success'})`, `labels({v => 'Text'})` | Badge (`success info warning danger neutral`) |
| `integer`, `min`, `max`, `step` | Number |
| `rows` | Textarea |
| `max_kb`, `mimes([qw(pdf png)])` | Image/File (svg is not accepted for images) |
| `hide_from_index`, `hide_from_detail`, `hide_when_creating`, `hide_when_updating`, `only_on_index`, `only_on_detail`, `only_on_forms`, `except_on_forms` | visibility |
| `using(sub ($model, $c) {...})` | computed, read-only column |
| `display_using(sub ($value, $model, $c) {...})`, `fill_using(sub ($c, $model, $value) {...})` | custom read / write |

Rules you can use are FormRequest's (`required`, `min`, `max`, `email`, `regex:`, `in:`, `unique:`, `exists:` …).
Error text is a fragment ("is required") and the client prefixes the field label.

Notes
* **Password** hashes with Heimdall; blank on update keeps the hash. Do not also hash in a model mutator.
* **DateTime** values are stored/sent as UTC and shown in the browser's time zone.
* Two fields can share a column (e.g. a `Badge` for reading and a `Select` for editing, see the demo `Post`).
* `unique` also counts soft-deleted rows.

## Filters, actions, metrics

```perl
use Mojolicious::Plugin::Skinir::Filter qw(SelectFilter BooleanFilter TextFilter DateFilter);
SelectFilter('Status', 'status', {draft => 'Draft'});
SelectFilter('Mine', 'mine', {1 => 'Mine'})->using(sub ($c, $q, $v) { $q->where(user_id => $c->skinir_user->get_key) });

use Mojolicious::Plugin::Skinir::Action;
Mojolicious::Plugin::Skinir::Action->new(
  name => 'Publish', confirm_text => 'Publish them?', destructive => 0, standalone => 0,
  fields  => [ Select('Visibility')->options({public => 'Public'})->required ],   # no BelongsTo here
  handler => sub ($c, $models, $fields) { $models->each(sub { $_->update({...}) }); {message => 'Done'} },
);   # returns {type => 'success|error', message, redirect}

use Mojolicious::Plugin::Skinir::Metric qw(ValueMetric TrendMetric PartitionMetric);
ValueMetric('Revenue', model => 'Order', aggregate => 'sum', column => 'total', prefix => '$');
TrendMetric('Signups', model => 'User', unit => 'day', ranges => [7, 30, 90]);          # unit: day|month
PartitionMetric('By status', model => 'Post', group_by => 'status', labels => {...});
# common options: filter => sub ($c, $q) {...}, date_column (default created_at), decimals, prefix, suffix, width ('1/3'|'2/3'|'full')
```

Actions run only on rows the user may `update` (or `delete` when `destructive`) — override with `ability`.
Value ranges: any number of days, `TODAY MTD YTD ALL`. Trend/partition SQL is driver aware (SQLite, MariaDB, PostgreSQL).
Metrics are computed in the database; timestamps are UTC.

## Authorization

Policies are plain Policy-plugin classes. Subclass `Mojolicious::Plugin::Skinir::Policy` (allows every signed-in
panel user) and override what you need. Abilities: `view_any view create update delete restore force_delete`.
`view_any` and `create` receive a blank model. In policies use `$c->skinir_user`.
Unknown abilities are **denied**. The UI hides what the API would refuse, but the API enforces everything.

## i18n

Built in: `en`, `fr` (`lib/.../resources/lang/*.json`). Override or add anything in your own `i18n/<locale>.json`
(Translatable) — flat or nested keys under `skinir.`:

```json
{ "skinir": {
  "dashboard": "Home",
  "resources": { "posts": { "label": "Articles", "singular": "article" } },
  "fields":    { "posts": { "title": "Titre" } },
  "groups":    { "content": "Contenu" },
  "metrics":   { "dashboard": { "new-posts": "Nouveaux articles" } },
  "actions":   { "posts": { "set-status": "Changer le statut" } } } }
```

Add a language: put `xx.json` next to `en.json` in the plugin (or only override strings) and list it in `locales`.

## Front end

`app.js` (Vue 3 global build, string templates — no build step on the app side) and `skinir.css` (Tailwind 4,
class-based dark mode) ship pre-built under `resources/public/skinir/`.

* **Re-theme without rebuilding**: add a stylesheet via `styles` with `:root { --skinir-600: #0d9488; --skinir-700: #0f766e; }` (shades 50–950).
* **Rebuild the assets** after changing the client source: `cd assets && npm install && npm run build` (Tailwind 4 + esbuild).
* **Vue**: loaded from jsDelivr by default; `script/app skinir assets:vue` downloads it and `vue => 'local'` serves it yourself.
  The runtime template compiler needs `'unsafe-eval'` in a CSP.
* **Custom field type** (load the script via `scripts`):

```js
Skinir.field('rating', {
  display: { props: ['field', 'value'], template: '<span>{{ "★".repeat(value) }}</span>' },
  input:   { props: ['field', 'modelValue', 'error'], emits: ['update:modelValue'],
             template: '<input type="number" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)">' },
});
```
  Also available: `Skinir.api(method, path, body)`, `Skinir.toast(type, msg)`, `Skinir.confirm({...})`, `Skinir.navigate(path)`, `Skinir.component(name, def)`.

## CLI

```
skinir make:resource <Name> [--model Model]
skinir make:policy   <Name>
skinir make:user     <email> [name]            # password prompt, or SKINIR_PASSWORD
skinir assets:vue    [--version 3.5.13]
```

## JSON API (under `<path>/skinir-api`, session + `X-CSRF-Token` header on writes)

```
GET  bootstrap · POST locale · POST logout
GET  metrics/dashboard/:key · GET metrics/resources/:resource/:key        ?range=
GET  resources/:r          ?search &page &per_page &order_by &order_dir &trashed=with|only &filters={json}
POST resources/:r · GET resources/:r/creation-fields
GET  resources/:r/:id · PUT resources/:r/:id · DELETE resources/:r/:id · GET resources/:r/:id/update-fields
POST resources/:r/:id/restore · DELETE resources/:r/:id/force
POST resources/:r/bulk {op: delete|restore|force_delete, ids}
POST resources/:r/actions/:key {ids, <action fields>}
GET  resources/:r/options/:attribute ?search &current
```

## Security model

* Session cookie (signed by Mojolicious; set `sameSite`, and `secure` in production), expiry 8 h, separate from your site's login.
* CSRF: login form uses Mojolicious' token; every non-GET API call needs `X-CSRF-Token` (the shell page embeds it); constant-time compare.
* Login: unknown users cost the same time as wrong passwords, per-IP throttle, redirect target restricted to the panel.
* Authorization on every endpoint, per row; mass assignment is limited to fields the resource declares and the user may edit.
* Sort columns and filter values are whitelisted; all SQL values are bound; metric identifiers are validated.
* Uploads: extension whitelist, size limit, random names, no SVG for images, deletes only inside the uploads directory.
* Client renders values with Vue text interpolation (no `v-html` except fixed icon paths); links only for `http(s)` URLs.

## Limitations (v0.01)

No nested/polymorphic relations, no many-to-many field, no per-field authorization, no lenses/dashboards beyond cards,
no undo, English validation messages, in-process login throttle, composite primary keys unsupported.
