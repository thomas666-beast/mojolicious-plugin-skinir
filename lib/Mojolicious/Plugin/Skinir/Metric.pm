package Mojolicious::Plugin::Skinir::Metric;
use Mojo::Base -base, -signatures;

use Exporter 'import';
use POSIX qw(strftime floor);
use Time::Local qw(timegm);

our @EXPORT_OK = qw(ValueMetric TrendMetric PartitionMetric);

has [qw(key label type model aggregate column date_column unit prefix suffix decimals
  ranges filter labels limit width group_by default_range)];

my %AGG = map { $_ => 1 } qw(count sum avg min max);

sub new ($class, @args) {
  my $self = $class->SUPER::new(@args);
  unless (defined $self->{key}) {
    (my $k = lc($self->{label} // 'metric')) =~ s/[^a-z0-9]+/-/g;
    $k =~ s/\A-+|-+\z//g;
    $self->{key} = $k;
  }
  $self->{aggregate} //= 'count';
  die "Skinir metric: unknown aggregate '$self->{aggregate}'\n" unless $AGG{$self->{aggregate}};
  $self->{date_column} = 'created_at' unless exists $self->{date_column};
  $self->{width} //= '1/3';
  if (!$self->{ranges}) {
    $self->{ranges} = $self->{type} eq 'value' ? [7, 30, 60, 365, 'TODAY', 'MTD', 'YTD', 'ALL']
                    : $self->{type} eq 'trend' ? [7, 30, 90]
                    :                            [];
  }
  $self->{default_range} //= ($self->{ranges}[1] // $self->{ranges}[0]);
  return $self;
}

# ValueMetric('Users', model => 'User')
# ValueMetric('Revenue', model => 'Order', aggregate => 'sum', column => 'total', prefix => '$')
# TrendMetric('Signups', model => 'User', unit => 'day', ranges => [7, 30])
# PartitionMetric('By status', model => 'Post', group_by => 'status', labels => {...})
sub ValueMetric     ($label, %o) { __PACKAGE__->new(type => 'value',     label => $label, %o) }
sub TrendMetric     ($label, %o) { __PACKAGE__->new(type => 'trend',     label => $label, %o) }
sub PartitionMetric ($label, %o) { __PACKAGE__->new(type => 'partition', label => $label, %o) }

sub meta ($self, $c, $scope) {
  return {
    key           => $self->{key},
    label         => $c->skinir->tr_or($c, "metrics.$scope.$self->{key}", $self->{label}),
    type          => $self->{type},
    ranges        => $self->{ranges},
    default_range => $self->{default_range},
    unit          => ($self->{unit} // 'day'),
    prefix        => $self->{prefix},
    suffix        => $self->{suffix},
    decimals      => $self->{decimals} // 0,
    width         => $self->{width},
  };
}

# ---- helpers ---------------------------------------------------------------------
sub _ts ($epoch) { strftime('%Y-%m-%d %H:%M:%S', gmtime $epoch) }

sub _query ($self, $c) {
  my $class = $c->model($self->{model});
  my $q = $class->query;
  $self->{filter}->($c, $q) if $self->{filter};
  return ($class, $q);
}

# (start, previous_start, previous_end) as epoch seconds; empty list = all time
sub _window ($self, $range, $now = time) {
  return () unless defined $range;
  if ($range =~ /\A\d+\z/) {
    my $span  = $range * 86400;
    my $start = $now - $span;
    return ($start, $start - $span, $start);
  }
  my @t = gmtime $now;
  my ($start, $pstart);
  if ($range eq 'TODAY') {
    $start  = timegm(0, 0, 0, $t[3], $t[4], $t[5]);
    $pstart = $start - 86400;
  }
  elsif ($range eq 'MTD') {
    $start  = timegm(0, 0, 0, 1, $t[4], $t[5]);
    $pstart = $t[4] ? timegm(0, 0, 0, 1, $t[4] - 1, $t[5]) : timegm(0, 0, 0, 1, 11, $t[5] - 1);
  }
  elsif ($range eq 'YTD') {
    $start  = timegm(0, 0, 0, 1, 0, $t[5]);
    $pstart = timegm(0, 0, 0, 1, 0, $t[5] - 1);
  }
  else { return () }
  my $pend = $pstart + ($now - $start);
  $pend = $start if $pend > $start;
  return ($start, $pstart, $pend);
}

sub _wrap ($self, $class, $col) {
  die "Skinir metric: invalid column '$col'\n" unless $col =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
  return $class->connection->grammar->wrap($class->table . '.' . $col);
}

sub _agg_sql ($self, $class) {
  my $fn = $self->{aggregate};
  return 'count(*)' if $fn eq 'count';
  die "Skinir metric: '$fn' needs a column\n" unless defined $self->{column};
  return "$fn(" . $self->_wrap($class, $self->{column}) . ')';
}

sub _aggregate ($self, $q) {
  my $fn = $self->{aggregate};
  return $fn eq 'count' ? $q->count : $q->$fn($self->{column});
}

sub _round ($self, $v) {
  return undef unless defined $v;
  my $d = $self->{decimals} // 0;
  return 0 + sprintf("%.${d}f", $v);
}

# ---- calculation ---------------------------------------------------------------------
sub calculate ($self, $c, $range = undef) {
  $range //= $self->{default_range};
  die "Skinir metric: range '$range' is not allowed\n"
    if defined $range && @{$self->{ranges}} && !grep { "$_" eq "$range" } @{$self->{ranges}};
  my $m = "_calc_$self->{type}";
  return $self->$m($c, $range);
}

sub _calc_value ($self, $c, $range) {
  my ($class, $q) = $self->_query($c);
  my $dc = $self->{date_column};
  my @w  = defined $dc ? $self->_window($range) : ();

  unless (@w) {
    return {value => $self->_round($self->_aggregate($q)), previous => undef, change => undef};
  }
  my $cur  = $q->clone->where($dc, '>=', _ts($w[0]));
  my $prev = $q->clone->where($dc, '>=', _ts($w[1]))->where($dc, '<', _ts($w[2]));
  my ($v, $p) = ($self->_aggregate($cur) // 0, $self->_aggregate($prev) // 0);
  my $change = $p ? $self->_round_pct(($v - $p) / abs($p) * 100) : undef;
  return {value => $self->_round($v), previous => $self->_round($p), change => $change};
}

sub _round_pct ($self, $v) { 0 + sprintf('%.0f', $v) }

sub _bucket_expr ($self, $class, $unit) {
  my $drv = $class->connection->driver;
  my $col = $self->_wrap($class, $self->{date_column});
  my $month = $unit eq 'month';
  return $drv eq 'sqlite' ? "strftime('" . ($month ? '%Y-%m' : '%Y-%m-%d') . "', $col)"
       : $drv eq 'mysql'  ? "date_format($col, '" . ($month ? '%Y-%m' : '%Y-%m-%d') . "')"
       :                    "to_char($col, '" . ($month ? 'YYYY-MM' : 'YYYY-MM-DD') . "')";
}

sub _calc_trend ($self, $c, $range) {
  die "Skinir trend metric needs a date_column\n" unless defined $self->{date_column};
  my $unit = $self->{unit} // 'day';
  die "Skinir trend metric: unit must be 'day' or 'month'\n" unless $unit =~ /\A(?:day|month)\z/;
  my $n = $range =~ /\A\d+\z/ && $range > 0 ? $range : 30;

  my ($class, $q) = $self->_query($c);
  my @t = gmtime;
  my (@labels, $start);
  if ($unit eq 'day') {
    my $today = timegm(0, 0, 0, $t[3], $t[4], $t[5]);
    $start = $today - ($n - 1) * 86400;
    @labels = map { strftime('%Y-%m-%d', gmtime($start + $_ * 86400)) } 0 .. $n - 1;
  }
  else {
    my ($y, $m) = ($t[5] + 1900, $t[4]);
    my @ym;
    for (1 .. $n) { unshift @ym, [$y, $m]; if (--$m < 0) { $m = 11; $y-- } }
    @labels = map { sprintf '%04d-%02d', $_->[0], $_->[1] + 1 } @ym;
    $start = timegm(0, 0, 0, 1, $ym[0][1], $ym[0][0]);
  }

  my $expr = $self->_bucket_expr($class, $unit);
  my $sel  = $q->clone->where($self->{date_column}, '>=', _ts($start))
    ->select(\"$expr as bucket", \($self->_agg_sql($class) . ' as aggregate'))
    ->group_by(\$expr)->order_by_raw('bucket asc');
  my ($sql, $bind) = $sel->compile;
  my %hit = map { ($_->{bucket} => $_->{aggregate}) } @{$class->connection->select_all($sql, @$bind)};

  my @values = map { $self->_round($hit{$_} // 0) } @labels;
  my $total = 0;
  $total += $_ for @values;
  return {labels => \@labels, values => \@values, total => $self->_round($total)};
}

sub _calc_partition ($self, $c, $range) {
  my $gc = $self->{group_by} // die "Skinir partition metric needs group_by\n";
  my ($class, $q) = $self->_query($c);
  if (defined $self->{date_column} && defined $range) {
    my @w = $self->_window($range);
    $q = $q->clone->where($self->{date_column}, '>=', _ts($w[0])) if @w;
  }
  my $g    = $self->_wrap($class, $gc);
  my $sel  = $q->clone->select(\"$g as label", \($self->_agg_sql($class) . ' as aggregate'))
    ->group_by(\$g)->order_by_raw('aggregate desc')->limit($self->{limit} // 10);
  my ($sql, $bind) = $sel->compile;
  my $map  = $self->{labels} // {};
  my @items = map {
    my $l = $_->{label};
    +{label => (defined $l ? ($map->{$l} // "$l") : 'None'), value => $self->_round($_->{aggregate} // 0)}
  } @{$class->connection->select_all($sql, @$bind)};
  return {items => \@items};
}

1;

__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Skinir::Metric - dashboard / resource cards

=head1 SYNOPSIS

  use Mojolicious::Plugin::Skinir::Metric qw(ValueMetric TrendMetric PartitionMetric);

  sub cards ($self, $c) {[
    ValueMetric('Posts', model => 'Post'),
    TrendMetric('New users', model => 'User', unit => 'day', ranges => [7, 30]),
    PartitionMetric('By status', model => 'Post', group_by => 'status',
      labels => {draft => 'Draft', published => 'Published'}),
  ]}

=cut
