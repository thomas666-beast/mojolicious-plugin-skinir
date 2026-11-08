use strict;
use warnings;
use feature "signatures";
no warnings "experimental::signatures";
use JSON::PP ();
use Test::More;
use FindBin;
require "$FindBin::Bin/lib_fakes.pl";

use Mojolicious::Plugin::Skinir::Fields;

my $c   = Fake::C->new;
my $cls = 'Fake::Class';
my $res = Fake::Resource->new;

# ---- constructors / attribute derivation -------------------------------------------------
my $f = Text('Full name');
is $f->attribute, 'full_name', 'attribute derived from label';
is(Text('Name', 'title')->attribute, 'title', 'explicit attribute');
is $f->type, 'text', 'type';
ok ID()->is_sortable && ID()->is_readonly, 'ID is sortable + readonly';
ok !ID()->shown_on('create'), 'ID hidden on forms';
ok !Password()->shown_on('index'), 'password only on forms';
ok !HasMany('Posts', 'posts', 'posts')->shown_on('create'), 'has_many only on detail';

# ---- fluent flags ------------------------------------------------------------------------------
my $t = Text('Name')->sortable->required->help('hi')->placeholder('x');
ok $t->is_sortable && $t->is_required, 'flags set';
is $t->help, 'hi', 'prop getter';
is(Text('A')->hide_from_index->shown_on('index'), 0, 'hide_from_index');
my $o = Text('A')->only_on_forms;
ok !$o->shown_on('index') && $o->shown_on('create') && $o->shown_on('update'), 'only_on_forms';

# ---- rules --------------------------------------------------------------------------------------
is(Text('A')->compile_rules($c, 'create', $cls), 'nullable', 'optional text => nullable');
is(Text('A')->required->compile_rules($c, 'create', $cls), 'required', 'required flag');
is(Text('A')->rules('required|max:5')->compile_rules($c, 'create', $cls), 'required|max:5', 'user rule string, no duplicate required');
is(Email('E')->rules('required')->compile_rules($c, 'create', $cls), 'email|required', 'email adds email rule');
is(Boolean('B')->compile_rules($c, 'create', $cls), 'nullable|boolean', 'boolean rule');
is(Number('N')->integer->min(1)->max(9)->compile_rules($c, 'create', $cls), 'nullable|integer|min:1|max:9', 'number rules');
is(Text('S')->unique->compile_rules($c, 'create', $cls), 'nullable|unique:items,s', 'unique on create');
is(Text('S')->unique->compile_rules($c, 'update', $cls, 7), 'nullable|unique:items,s,7,id', 'unique ignores current row on update');
is(Text('A')->creation_rules('required')->compile_rules($c, 'create', $cls), 'required', 'creation rules apply on create');
is(Text('A')->creation_rules('required')->compile_rules($c, 'update', $cls), 'nullable', '...but not on update');
is(Text('A')->update_rules('min:3')->compile_rules($c, 'update', $cls), 'nullable|min:3', 'update rules apply on update');
ok !defined Text('A')->readonly->compile_rules($c, 'create', $cls), 'readonly is not validated';
ok !defined ID()->compile_rules($c, 'update', $cls), 'ID is not validated';
ok !defined Image('I')->compile_rules($c, 'create', $cls), 'uploads are validated separately';

my $sel = Select('Status')->options({draft => 'Draft', live => 'Live'})->rules('required')->compile_rules($c, 'create', $cls);
is ref $sel, 'ARRAY', 'select compiles to an arrayref (has a code rule)';
is $sel->[0], 'required', 'select keeps required first';
my ($code) = grep { ref $_ eq 'CODE' } @$sel;
ok $code->('draft', [], {}, {}), 'select accepts a listed option';
ok !$code->('hacked', [], {}, {}), 'select rejects an unlisted option';

my $dt = DateTime('When')->compile_rules($c, 'create', $cls);
my ($dc) = grep { ref $_ eq 'CODE' } @$dt;
ok $dc->('2026-11-08 10:30:00', [], {}, {}), 'datetime accepts SQL form';
ok $dc->('2026-11-08T10:30', [], {}, {}),    'datetime accepts datetime-local form';
ok !$dc->('tomorrow', [], {}, {}),           'datetime rejects garbage';

# ---- options ---------------------------------------------------------------------------------------
is_deeply Select('S')->options({b => 'Banana', a => 'Apple'})->option_list,
  [{value => 'a', label => 'Apple'}, {value => 'b', label => 'Banana'}], 'hash options sorted by label';
is_deeply Select('S')->options([qw(x y)])->option_list, [{value => 'x', label => 'x'}, {value => 'y', label => 'y'}], 'list options';
is_deeply Select('S')->options([[1 => 'One']])->option_list, [{value => 1, label => 'One'}], 'pair options';

# ---- filling a model ----------------------------------------------------------------------------------
my $m = Fake::Model->new;
Text('Name')->fill($c, $m, {name => 'Ann'});
is $m->get_attribute('name'), 'Ann', 'text filled';

$m = Fake::Model->new;
Text('Name')->fill($c, $m, {name => ''});
is $m->get_attribute('name'), '', 'empty text stays empty string (NOT NULL columns)';
Text('Name')->nullable->fill($c, $m, {name => ''});
ok !defined $m->get_attribute('name'), 'nullable empty text becomes NULL';
Number('N')->fill($c, $m, {n => ''});
ok !defined $m->get_attribute('n'), 'empty number becomes NULL';
Number('N')->fill($c, $m, {n => '12.50'});
is $m->get_attribute('n'), 12.5, 'number is numeric';

Boolean('Flag')->fill($c, $m, {flag => 'true'});
is $m->get_attribute('flag'), 1, 'boolean "true" => 1';
Boolean('Flag')->fill($c, $m, {flag => 'false'});
is $m->get_attribute('flag'), 0, 'boolean "false" => 0';
Boolean('Flag')->fill($c, $m, {flag => JSON::PP::false()});
is $m->get_attribute('flag'), 0, 'JSON false => 0';
my $fresh = Fake::Model->new;
Boolean('Flag')->fill($c, $fresh, {});
is $fresh->get_attribute('flag'), 0, 'absent boolean defaults to 0 on create';

DateTime('At')->fill($c, $m, {at => '2026-11-08T10:30:00Z'});
is $m->get_attribute('at'), '2026-11-08 10:30:00', 'datetime normalised to SQL UTC';
DateTime('At')->fill($c, $m, {at => '2026-11-08T10:30'});
is $m->get_attribute('at'), '2026-11-08 10:30:00', 'datetime-local gets seconds';

Text('Name')->readonly->fill($c, $m, {name => 'hacked'});
isnt $m->get_attribute('name'), 'hacked', 'readonly never filled';
my $before = $m->get_attribute('name');
Text('Name')->fill($c, $m, {other => 'x'});
is $m->get_attribute('name'), $before, 'key absent from validated data leaves attribute alone';

Text('Name')->fill_using(sub ($c, $model, $v) { $model->set_attribute(name => uc $v) })->fill($c, $m, {name => 'abc'});
is $m->get_attribute('name'), 'ABC', 'fill_using';

$m = Fake::Model->new; $m->{casts} = {meta => 'json'};
Code('Meta')->fill($c, $m, {meta => '{"a":1}'});
is_deeply $m->get_attribute('meta'), {a => 1}, 'json cast: text decoded before storing';

# ---- display -------------------------------------------------------------------------------------------------
$m = Fake::Model->new(flag => 1, at => '2026-11-08 10:30:00', n => '5', pw => 'hash', status => 'live');
is_deeply Boolean('Flag')->display($c, $m), \1, 'boolean display';
is DateTime('At')->display($c, $m), '2026-11-08T10:30:00Z', 'datetime shown as ISO UTC';
is Number('N')->display($c, $m), 5, 'number display numeric';
ok !defined Password('Pw')->display($c, $m), 'password never displayed';
is Text('Status')->display_using(sub ($v, $mm, $cc) { "<$v>" })->display($c, $m), '<live>', 'display_using';
is Text('X')->using(sub ($mm, $cc) { 'computed' })->display($c, $m), 'computed', 'computed field';
ok !Text('X')->using(sub { 1 })->is_fillable, 'computed fields are not fillable';

# ---- metadata ----------------------------------------------------------------------------------------------------
my $meta = Select('Status')->options({a => 'A'})->required->help('h')->meta($c, $res);
is $meta->{type}, 'select', 'meta type';
is_deeply $meta->{options}, [{value => 'a', label => 'A'}], 'meta options';
is_deeply $meta->{required}, \1, 'meta required';
is $meta->{help}, 'h', 'meta help';
is_deeply Number('N')->integer->meta($c, $res)->{step}, 1, 'integer step';
like Image('I')->meta($c, $res)->{accept}, qr/\.png/, 'image accept list';
unlike Image('I')->meta($c, $res)->{accept}, qr/svg/, 'svg is not an allowed image type (stored XSS)';

done_testing;
