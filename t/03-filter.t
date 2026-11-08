use strict;
use warnings;
use feature "signatures";
no warnings "experimental::signatures";
use JSON::PP ();
use Test::More;
use FindBin;
require "$FindBin::Bin/lib_fakes.pl";

use Mojolicious::Plugin::Skinir::Filter qw(SelectFilter BooleanFilter TextFilter DateFilter);

my $c = Fake::C->new;

my $f = SelectFilter('Status', 'status', {draft => 'Draft', live => 'Live'});
is $f->key, 'status', 'key defaults to attribute';
my $q = Fake::Query->new;
$f->apply($c, $q, 'live');
is_deeply $q->calls, [['where', 'status', 'live']], 'select applies equality';
$q = Fake::Query->new;
$f->apply($c, $q, "x' OR 1=1 --");
is_deeply $q->calls, [], 'select ignores values that are not listed options';

$q = Fake::Query->new;
BooleanFilter('F', 'featured')->apply($c, $q, 'true');
BooleanFilter('F', 'featured')->apply($c, $q, 'false');
is_deeply $q->calls, [['where', 'featured', 1], ['where', 'featured', 0]], 'boolean filter';

$q = Fake::Query->new;
TextFilter('T', 'title')->apply($c, $q, 'foo');
is_deeply $q->calls, [['where', 'title', 'ilike', '%foo%']], 'text filter uses ilike';

$q = Fake::Query->new;
DateFilter('D', 'created_at')->apply($c, $q, {from => '2026-01-01', to => '2026-01-31'});
is_deeply $q->calls, [['where', 'created_at', '>=', '2026-01-01 00:00:00'], ['where', 'created_at', '<=', '2026-01-31 23:59:59']], 'date range';

$q = Fake::Query->new;
DateFilter('D', 'created_at')->apply($c, $q, {from => 'garbage', to => "2026-01-31'; drop table x"});
is_deeply $q->calls, [], 'malformed dates are ignored';

$q = Fake::Query->new;
SelectFilter('Mine', 'mine', {1 => 'Mine'})->using(sub ($c, $q, $v) { $q->where(owner => 5) })->apply($c, $q, 1);
is_deeply $q->calls, [['where', 'owner', 5]], 'custom handler';

is_deeply [map { $_->{value} } @{$f->meta($c)->{options}}], [qw(draft live)], 'meta options';

done_testing;
