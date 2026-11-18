use Mojo::Base -strict, -signatures;
use Mojo::JSON qw(false);
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../examples/lib";
use SkinirDemo;

my $app = SkinirDemo->new(mode => 'testing');
$app->log->level('fatal');
my $t = Test::Mojo->new($app);
my $api = '/admin/skinir-api';
my $tickets = "$api/resources/tickets";
my $queues = "$api/resources/queues";

sub sign_in ($t, $email, $expected = 302) {
  $t->get_ok('/admin/login')->status_is(200)->header_is('Cache-Control', 'no-store');
  my $token = $t->tx->res->dom->at('input[name=csrf_token]')->{value};
  $t->post_ok('/admin/login' => form => {
    identifier => $email, password => 'demo-only-passphrase', csrf_token => $token,
  })->status_is($expected);
  return {} unless $expected == 302;
  $t->get_ok('/admin')->status_is(200)->header_is('Cache-Control', 'no-store');
  return {'X-CSRF-Token' => $t->tx->res->dom->at('meta[name=csrf-token]')->{content}};
}

$t->get_ok('/admin')->status_is(302)->header_is(Location => '/admin/login');
$t->get_ok("$api/bootstrap")->status_is(401);
$t->get_ok('/skinir/app.js')->status_is(200)->content_like(qr/Skinir\.boot/);
$t->get_ok('/skinir/skinir.css')->status_is(200);
my $customer = Test::Mojo->new($app);
sign_in($customer, 'customer@example.test', 422);
$customer->get_ok("$api/bootstrap")->status_is(401);
my $csrf = sign_in($t, 'operator@example.test');
$t->get_ok("$api/bootstrap")->status_is(200)->json_is('/user/login', 'operator@example.test');

$t->get_ok($tickets)->status_is(200)->json_is('/meta/total', 12)->json_is('/meta/per_page', 10);
is scalar @{$t->tx->res->json->{data}}, 10, 'first page is bounded';
$t->get_ok("$tickets?page=2")->status_is(200)->json_is('/meta/current_page', 2);
is scalar @{$t->tx->res->json->{data}}, 2, 'second page contains the remaining rows';
$t->get_ok("$tickets?search=Example+ticket+12")->status_is(200)->json_is('/data/0/id', 12);
$t->get_ok("$tickets?filters=%7B%22status%22%3A%22closed%22%7D")->status_is(200)->json_is('/meta/total', 2);
$t->get_ok("$tickets?filters=%5B%5D")->status_is(422);
$t->get_ok("$tickets?page=100001")->status_is(422);
$t->get_ok("$tickets?per_page=500")->status_is(422);
$t->get_ok("$tickets/13")->status_is(404);
$t->get_ok("$tickets/1")->status_is(200)->json_is('/fields/3/value/title', 'Support');
$t->get_ok("$queues/1")->status_is(200)->json_is('/panels/0/total', 3)->json_is('/panels/0/rows/0/id', 1);
$t->get_ok("$tickets/options/queue_id?current=2")->status_is(200)
  ->json_is('/data/0/label', 'Billing')->json_is('/data/1/label', 'Support')->json_hasnt('/data/2');
$t->get_ok("$api/metrics/dashboard/visible-tickets")->status_is(200)->json_is('/value', 12);
$t->get_ok("$api/metrics/resources/tickets/visible-tickets")->status_is(200)->json_is('/value', 12);

$t->post_ok($tickets => json => {})->status_is(419, 'API write requires CSRF');
$t->post_ok("$api/locale" => $csrf => json => [])->status_is(422);
$t->post_ok("$api/locale" => $csrf => json => {locale => 'fr'})->status_is(200);
$t->get_ok("$api/bootstrap")->status_is(200)->json_is('/locale', 'fr');
$t->post_ok("$api/locale" => $csrf => json => {locale => 'en'})->status_is(200);
$t->post_ok($tickets => $csrf => json => {subject => 'A new ticket', queue_id => 1})
  ->status_is(422)->json_has('/errors/status');
$t->post_ok($tickets => $csrf => json => {subject => 'A new ticket', status => 'open', queue_id => 2})
  ->status_is(422)->json_has('/errors/queue_id');
$t->post_ok($tickets => $csrf => json => {subject => 'Example ticket 1', status => 'open', queue_id => 1})
  ->status_is(422)->json_has('/errors/subject');
$t->post_ok($tickets => $csrf => json => {subject => 'A new ticket', status => 'open', queue_id => 1})
  ->status_is(201)->json_is('/title', 'A new ticket');
my $id = $t->tx->res->json->{id};
$t->put_ok("$tickets/$id" => $csrf => json => {subject => 'Updated ticket', status => 'open', queue_id => 3})
  ->status_is(200)->json_is('/title', 'Updated ticket');
$t->get_ok("$tickets/$id/update-fields")->status_is(200)->json_is('/fields/2/current/title', 'Billing');

my %ticket_form = (subject => 'Updated ticket', status => 'open', queue_id => 3);
sub upload ($text) { return {content => $text, filename => 'example.txt'} }
$t->put_ok("$tickets/$id" => $csrf => form => {%ticket_form, attachment => upload('First file')})
  ->status_is(200);
$t->get_ok("$tickets/$id")->status_is(200);
my $old = $t->tx->res->json->{fields}[4]{value}{url};
$t->get_ok($old)->status_is(200)->content_is('First file');
{
  no warnings qw(redefine once);
  local *SkinirDemo::Resource::Ticket::after_save = sub { die "Stop the test transaction\n" };
  $t->put_ok("$tickets/$id" => $csrf => form => {%ticket_form, attachment => upload('Rejected replacement')})
    ->status_is(500);
}
$t->get_ok($old)->status_is(200)->content_is('First file');
my $files = $app->home->child(qw(public uploads skinir tickets));
is $files->list->size, 1, 'rolled back write leaves only the old file';
$t->put_ok("$tickets/$id" => $csrf => form => {%ticket_form, attachment => upload('New file')})
  ->status_is(200);
$t->get_ok($old)->status_is(404);
$t->get_ok("$tickets/$id")->status_is(200);
my $new = $t->tx->res->json->{fields}[4]{value}{url};
$t->get_ok($new)->status_is(200)->content_is('New file');

$t->post_ok("$tickets/actions/close-selected" => $csrf => json => {ids => [$id]})
  ->status_is(200)->json_is('/message', 'Tickets closed');
$t->get_ok("$tickets/$id")->status_is(200)->json_is('/fields/2/value', 'closed');
$t->post_ok("$tickets/actions/close-selected" => $csrf => json => {ids => [$id, 13]})->status_is(404);
$t->post_ok("$tickets/bulk" => $csrf => json => [])->status_is(422);
$t->post_ok("$tickets/bulk" => $csrf => json => {op => 'delete', ids => [1 .. 501]})->status_is(422);
$t->delete_ok("$tickets/$id/force" => $csrf)->status_is(403);
$t->post_ok("$tickets/bulk" => $csrf => json => {op => 'force_delete', ids => [$id]})
  ->status_is(200)->json_is('/processed', 0)->json_is('/skipped', 1);
$t->delete_ok("$tickets/$id" => $csrf)->status_is(200);
$t->get_ok("$tickets?trashed=only")->status_is(200)->json_is('/meta/total', 1)->json_is('/data/0/id', $id);
$t->post_ok("$tickets/$id/restore" => $csrf)->status_is(200);
$t->post_ok("$tickets/bulk" => $csrf => json => {op => 'delete', ids => [$id, 13]})
  ->status_is(200)->json_is('/processed', 1)->json_is('/skipped', 1);
$t->delete_ok("$tickets/$id/force" => $csrf)->status_is(200);
$t->get_ok("$tickets/$id")->status_is(404);
$t->get_ok($new)->status_is(404);

my $viewer = Test::Mojo->new($app);
my $viewer_csrf = sign_in($viewer, 'viewer@example.test');
$viewer->get_ok($tickets)->status_is(200)->json_is('/resource/can_create', false);
$viewer->get_ok("$tickets/creation-fields")->status_is(403);
$viewer->post_ok("$tickets/actions/close-selected" => $viewer_csrf => json => {ids => [1]})->status_is(403);
$t->get_ok("$queues/creation-fields")->status_is(403);

my $independent = SkinirDemo->new(mode => 'testing');
$independent->log->level('fatal');
$independent->db('workspace')->dbh->do("UPDATE tickets SET subject = 'Separate app' WHERE id = 1");
my $other = Test::Mojo->new($independent);
sign_in($other, 'operator@example.test');
$other->get_ok("$tickets/1")->status_is(200)->json_is('/title', 'Separate app');
$t->get_ok("$tickets/1")->status_is(200)->json_is('/title', 'Example ticket 1');
$t->post_ok("$api/logout" => $csrf)->status_is(200);
$t->get_ok("$api/bootstrap")->status_is(401);

done_testing;
