use Mojo::Base -strict, -signatures;
use utf8;
use FindBin;
use Mojo::JSON qw(true false);
use Mojo::URL;
use Test::Mojo;
use Test::More;
use Text::CSV;
use lib "$FindBin::Bin/../examples/lib";
use SkinirDemo;

my $app = SkinirDemo->new(mode => 'testing');
$app->log->level('fatal');
my $operator = Test::Mojo->new($app);
my $viewer = Test::Mojo->new($app);
my $tickets = '/admin/skinir-api/resources/tickets';
my $export = "$tickets/export";

sub login ($t, $role) {
  $t->get_ok('/admin/login')->status_is(200);
  my $csrf = $t->tx->res->dom->at('input[name=csrf_token]')->{value};
  $t->post_ok('/admin/login' => form => {
    identifier => "$role\@example.test", password => 'demo-only-passphrase', csrf_token => $csrf,
  })->status_is(302);
  $t->get_ok('/admin')->status_is(200);
  return {'X-CSRF-Token' => $t->tx->res->dom->at('meta[name=csrf-token]')->{content}};
}

sub records ($t) {
  my $body = $t->tx->res->body;
  $body =~ s/\A\xef\xbb\xbf//;
  open my $fh, '<', \$body or die $!;
  binmode $fh, ':encoding(UTF-8)' or die $!;
  my $csv = Text::CSV->new({binary => 1, auto_diag => 2});
  return $csv->getline_all($fh);
}

$operator->post_ok($export)->status_is(401);
my $csrf = login($operator, 'operator');
my $reader_csrf = login($viewer, 'viewer');
$viewer->get_ok($tickets)->status_is(200)->json_is('/resource/can_export', false);
$viewer->post_ok($export => $reader_csrf)->status_is(403);
$operator->post_ok($export)->status_is(419, 'CSV requires CSRF');
$operator->get_ok($tickets)->status_is(200)->json_is('/resource/can_export', true);
$operator->post_ok('/admin/skinir-api/resources/queues/export' => $csrf)->status_is(403);

$operator->post_ok("$export?page=2&per_page=10&order_by=id&order_dir=asc" => $csrf)->status_is(200)
  ->header_is('Content-Type', 'text/csv; charset=UTF-8')
  ->header_is('Content-Disposition', 'attachment; filename="tickets.csv"')
  ->header_is('Cache-Control', 'no-store')->header_is('X-Content-Type-Options', 'nosniff');
like $operator->tx->res->body, qr/\A\xef\xbb\xbf.*\r\n/, 'UTF-8 BOM and CRLF row separators';
my $all = records($operator);
is_deeply shift @$all, [qw(ID Subject Status Queue)], 'explicit field order and labels';
is_deeply [map { $_->[0] } @$all], [1 .. 12], 'all permitted rows across pages; requested sort preserved';

my $filtered = Mojo::URL->new($export)->query({
  filters => '{"status":"closed"}', search => 'Example', order_by => 'id', order_dir => 'desc',
});
$operator->post_ok("$filtered" => $csrf)->status_is(200);
is_deeply [map { $_->[0] } @{records($operator)}], ['ID', 10, 5], 'filters, search and order match the index';
$operator->post_ok("$export?search=Nonexistent+subject" => $csrf)->status_is(200);
is_deeply records($operator), [[qw(ID Subject Status Queue)]], 'empty export includes headers';
$operator->post_ok("$export?filters=%5B%5D" => $csrf)->status_is(422);

my $db = $app->db('workspace')->dbh;
my @examples = ('  =1+1', "Crème, \"quoted\"\nnext line", "\tplain", "\x{ff1d}2");
for my $i (0 .. $#examples) {
  $db->do(q{INSERT INTO tickets (id, subject, status, queue_id) VALUES (?, ?, 'open', 2)}, undef, 20 + $i, $examples[$i]);
}
$operator->post_ok("$export?order_by=id&order_dir=asc" => $csrf)->status_is(200);
my %rows = map { $_->[0] => $_ } @{records($operator)};
is $rows{20}[1], "'  =1+1", 'neutralizes formula-looking text with leading space';
is $rows{21}[1], $examples[1], 'Unicode, commas, quotes and embedded newlines round trip';
is $rows{22}[1], "'\tplain", 'neutralizes leading control character';
is $rows{23}[1], "'$examples[3]", 'neutralizes fullwidth formula marker';
is $rows{20}[3], '', 'invisible related label is not exported';

$db->do("UPDATE tickets SET deleted_at = '2026-01-01 00:00:00' WHERE id = 21");
$operator->post_ok("$export?trashed=only" => $csrf)->status_is(200);
is_deeply [map { $_->[0] } @{records($operator)}], ['ID', 21], 'trash filter matches index semantics';

{
  no warnings qw(redefine once);
  local *SkinirDemo::Resource::Ticket::scope_query = sub { $_[2] };
  $operator->post_ok("$export?search=Example+ticket+13" => $csrf)->status_is(200);
  is_deeply records($operator), [[qw(ID Subject Status Queue)]], 'per-row view policy still applies without SQL scope';
}

$db->do('UPDATE tickets SET subject = ? WHERE id = 23', undef, 'X' x (5 * 1024 * 1024));
$operator->post_ok("$export?search=XXXX" => $csrf)->status_is(422)->header_isnt('Content-Type', 'text/csv; charset=UTF-8');
$db->do(q{
  WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<5001)
  INSERT INTO tickets (subject, status, queue_id) SELECT ('Batch row ' || i), 'open', 1 FROM n
});
$operator->post_ok("$export?search=Batch+row" => $csrf)->status_is(422)->json_like('/message', qr/Narrow your filters/);
$operator->post_ok("$export?search=Batch+row+500" => $csrf)->status_is(200);
is scalar @{records($operator)}, 4, 'narrower filtered export succeeds after limit error';

done_testing;
