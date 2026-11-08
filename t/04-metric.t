use strict;
use warnings;
use Test::More;
use Time::Local qw(timegm);

use Mojolicious::Plugin::Skinir::Metric qw(ValueMetric TrendMetric PartitionMetric);

my $v = ValueMetric('Active users', model => 'User');
is $v->key, 'active-users', 'key from label';
is $v->aggregate, 'count', 'default aggregate';
is $v->default_range, 30, 'default range';
ok scalar(grep { $_ eq 'MTD' } @{$v->ranges}), 'value ranges include MTD';

is_deeply(TrendMetric('T', model => 'User')->ranges, [7, 30, 90], 'trend ranges');
is_deeply(PartitionMetric('P', model => 'User', group_by => 'x')->ranges, [], 'partition has no ranges by default');

eval { ValueMetric('X', model => 'User', aggregate => 'drop table') };
like $@, qr/unknown aggregate/, 'aggregate is whitelisted';

# ---- time windows --------------------------------------------------------------------------------
my $now = timegm(30, 15, 12, 20, 5, 126);          # 2026-06-20 12:15:30 UTC
my ($s, $ps, $pe) = $v->_window(7, $now);
is $s, $now - 7 * 86400,  '7 days: start';
is $ps, $s - 7 * 86400,   '7 days: previous start';
is $pe, $s,               '7 days: previous end = start';

($s, $ps, $pe) = $v->_window('TODAY', $now);
is $s, timegm(0, 0, 0, 20, 5, 126), 'TODAY starts at midnight UTC';
is $pe - $ps, $now - $s, 'TODAY compares equal elapsed time';

($s, $ps, $pe) = $v->_window('MTD', $now);
is $s,  timegm(0, 0, 0, 1, 5, 126), 'MTD start';
is $ps, timegm(0, 0, 0, 1, 4, 126), 'MTD previous month start';

my $jan = timegm(0, 0, 0, 10, 0, 126);               # January: previous month is December of last year
($s, $ps) = $v->_window('MTD', $jan);
is $ps, timegm(0, 0, 0, 1, 11, 125), 'MTD in January looks at last December';

($s, $ps, $pe) = $v->_window('YTD', $now);
is $s,  timegm(0, 0, 0, 1, 0, 126), 'YTD start';
is $ps, timegm(0, 0, 0, 1, 0, 125), 'YTD previous start';
ok $pe <= $s, 'previous window never overlaps the current one';

is_deeply [$v->_window('ALL', $now)], [], 'ALL has no window';

done_testing;
