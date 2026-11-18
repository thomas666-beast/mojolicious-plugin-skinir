package SkinirDemo::Model::User;
use Mojo::Base 'Yggdrasil::Model', -signatures;
sub table { 'users' }
sub timestamps { 0 }

package SkinirDemo::Model::Ticket;
use Mojo::Base 'Yggdrasil::Model', -signatures;
use Moo;
with 'Yggdrasil::Role::SoftDeletes';
sub table { 'tickets' }
sub timestamps { 0 }

package SkinirDemo::Model::Queue;
use Mojo::Base 'Yggdrasil::Model', -signatures;
sub table { 'queues' }
sub timestamps { 0 }
sub tickets ($self) { $self->has_many('Ticket', 'queue_id') }

package SkinirDemo::Policy::Ticket;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Policy', -signatures;
sub view ($self, $c, $ticket) { !$ticket->get_attribute('private') }
sub create ($self, $c, $ticket) { $c->skinir_user->get_attribute('role') eq 'operator' }
sub update ($self, $c, $ticket) { $self->create($c, $ticket) }
sub delete ($self, $c, $ticket) { $self->create($c, $ticket) }
sub restore ($self, $c, $ticket) { $self->create($c, $ticket) }
sub force_delete ($self, $c, $ticket) { $self->create($c, $ticket) }
sub export ($self, $c, $ticket) { $self->create($c, $ticket) }

package SkinirDemo::Resource::Ticket;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Resource', -signatures;
use Mojolicious::Plugin::Skinir::Fields qw(ID Text Select BelongsTo File);
use Mojolicious::Plugin::Skinir::Filter qw(SelectFilter);
use Mojolicious::Plugin::Skinir::Metric qw(ValueMetric);
use Mojolicious::Plugin::Skinir::Action;
sub uri_key { 'tickets' }
sub model { 'Ticket' }
sub connection { 'workspace' }
sub title { 'subject' }
sub search { ['subject'] }
sub per_page { 10 }
sub policy { 'SkinirDemo::Policy::Ticket' }
sub scope_query ($self, $c, $q) { $q->where(private => 0) }
sub csv_columns ($self, $c) { [qw(id subject status queue_id)] }
sub fields ($self, $c) {[
  ID(),
  Text('Subject')->required->rules('max:120')->unique->sortable,
  Select('Status')->options({open => 'Open', closed => 'Closed'})->required,
  BelongsTo('Queue', 'queue_id', 'queues')->required,
  File('Attachment')->mimes(['txt'])->max_kb(64)->hide_from_index,
]}
sub filters ($self, $c) {[ SelectFilter('Status', 'status', {open => 'Open', closed => 'Closed'}) ]}
sub cards ($self, $c) {[ ValueMetric('Visible tickets', key => 'visible-tickets', date_column => undef, ranges => []) ]}
sub actions ($self, $c) {[
  Mojolicious::Plugin::Skinir::Action->new(
    name => 'Close selected',
    handler => sub ($c, $tickets, $fields) {
      $c->skinir->record($self)->connection->transaction(sub {
        $_->set_attribute(status => 'closed')->save for @$tickets;
      });
      return {message => 'Tickets closed'};
    },
  ),
]}

package SkinirDemo::Resource::Queue;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Resource', -signatures;
use Mojolicious::Plugin::Skinir::Fields qw(ID Text HasMany);
sub uri_key { 'queues' }
sub model { 'Queue' }
sub connection { 'workspace' }
sub title { 'name' }
sub scope_query ($self, $c, $q) { $q->where(hidden => 0) }
sub fields ($self, $c) {[ ID(), Text('Name'), HasMany('Tickets', 'tickets', 'tickets')->rows_limit(3) ]}

package SkinirDemo;
use Mojo::Base 'Mojolicious', -signatures;
use Crypt::Passphrase;
use Crypt::URandom qw(urandom);
use Mojo::File qw(tempdir);
use Mojolicious::Plugin::Skinir::Metric qw(ValueMetric);

sub startup ($self) {
  # Fresh, disposable database for each process. Never deploy the demo credentials.
  $self->{demo_dir} = tempdir;
  $self->home($self->{demo_dir});
  unshift @{$self->static->paths}, $self->home->child('public')->to_string;
  $self->secrets([unpack 'H*', urandom(32)]);
  $self->plugin(Yggdrasil => {
    legacy_global => 0,
    default => 'accounts',
    models => 'SkinirDemo::Model',
    connections => {
      accounts  => {driver => 'sqlite', database => 'accounts.db'},
      workspace => {driver => 'sqlite', database => 'workspace.db'},
    },
  });

  my $accounts = $self->db('accounts')->dbh;
  my $workspace = $self->db('workspace')->dbh;
  $accounts->do('CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, name TEXT, password TEXT, role TEXT NOT NULL)');
  $workspace->do('CREATE TABLE queues (id INTEGER PRIMARY KEY, name TEXT NOT NULL, hidden INTEGER NOT NULL DEFAULT 0)');
  $workspace->do(q{CREATE TABLE tickets (id INTEGER PRIMARY KEY, subject TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL, queue_id INTEGER NOT NULL REFERENCES queues(id), private INTEGER NOT NULL DEFAULT 0,
    attachment TEXT, deleted_at TEXT)});
  $workspace->do('CREATE INDEX tickets_visibility ON tickets(private, deleted_at, id)');
  $workspace->do("INSERT INTO queues (id, name, hidden) VALUES (1, 'Support', 0), (2, 'Internal', 1), (3, 'Billing', 0)");
  $workspace->do('INSERT INTO tickets (subject, status, queue_id, private) VALUES (?, ?, 1, ?)', undef,
    "Example ticket $_", $_ % 5 ? 'open' : 'closed', $_ == 13 ? 1 : 0) for 1 .. 13;
  my $password = Crypt::Passphrase->new(encoder => 'Argon2')->hash_password('demo-only-passphrase');
  $accounts->do('INSERT INTO users (email, name, password, role) VALUES (?, ?, ?, ?)', undef, @$_) for
    ['operator@example.test', 'Support operator', $password, 'operator'],
    ['viewer@example.test', 'Support viewer', $password, 'viewer'],
    ['customer@example.test', 'Customer', $password, 'customer'];

  $self->plugin(Skinir => {
    name => 'Skinir Support Desk',
    user_connection => 'accounts',
    gate => sub ($c, $user) { ($user->get_attribute('role') // '') =~ /\A(?:operator|viewer)\z/ },
    resources => ['SkinirDemo::Resource::Ticket', 'SkinirDemo::Resource::Queue'],
    cards => [ValueMetric('Visible tickets', key => 'visible-tickets', resource => 'tickets', date_column => undef, ranges => [])],
    (defined $ENV{SKINIR_DEMO_VUE} ? (vue => $ENV{SKINIR_DEMO_VUE}) : ()),
  });
  $self->routes->get('/' => sub ($c) { $c->redirect_to('/admin') });
}

1;
