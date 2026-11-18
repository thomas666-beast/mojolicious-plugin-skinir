# Build Your First Skinir App

Build Task Desk, a small Mojolicious app that stores tasks in SQLite. Start in an empty directory and finish with a sign-in, a task list, create and edit forms, a status filter, and CSV export. You do not need Laravel, PHP, Node.js, or any of the demo code.

## Create the project and install Skinir

You need Perl 5.20 or newer, `cpanm`, and a shell such as Bash. A compiler and `make` may be needed to install SQLite and password-hashing dependencies. Extract the Skinir 0.03 Release Bundle, open a terminal in the directory containing its `.tar.gz` files, then run:

```bash
mkdir taskdesk
cd taskdesk

cpanm -l "$PWD/local" \
  ../Yggdrasil-0.05.tar.gz \
  ../Mojolicious-Plugin-Yggdrasil-0.04.tar.gz \
  ../Mojolicious-Plugin-FormRequest-0.01.tar.gz \
  ../Mojolicious-Plugin-Policy-0.01.tar.gz \
  ../Mojolicious-Plugin-Translatable-0.01.tar.gz \
  DBD::SQLite \
  ../Mojolicious-Plugin-Skinir-0.03.tar.gz

export PERL5LIB="$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"
```

All the remaining commands run from `taskdesk/`. If you open a new terminal, set `PERL5LIB` again before running the app.

## Create the files

Copy this whole Bash block into your terminal. It creates the application, two models, a resource, an access policy, and a database setup command.

```bash
mkdir -p script db lib/TaskDesk/Model lib/TaskDesk/Resource lib/TaskDesk/Policy

cat > .gitignore <<'EOF'
/local/
/db/*.db*
EOF

cat > script/taskdesk <<'EOF'
#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojolicious::Commands;
Mojolicious::Commands->start_app('TaskDesk');
EOF

cat > lib/TaskDesk.pm <<'EOF'
package TaskDesk;
use Mojo::Base 'Mojolicious', -signatures;

sub startup ($self) {
  my $secret = $ENV{TASKDESK_SECRET} // '';
  die "Set TASKDESK_SECRET before starting Task Desk\n" if length($secret) < 32;
  $self->secrets([$secret]);

  $self->plugin(Yggdrasil => {
    driver => 'sqlite',
    database => 'db/taskdesk.db',
    models => 'TaskDesk::Model',
    legacy_global => 0,
  });

  $self->plugin(Skinir => {
    name => 'Task Desk',
    path => '/admin',
    resources => ['TaskDesk::Resource::Task'],
    gate => sub ($c, $user) {
      return ($user->get_attribute('role') // '') eq 'admin';
    },
  });

  $self->routes->get('/' => sub ($c) { $c->redirect_to('/admin') });
}

1;
EOF

cat > lib/TaskDesk/Model/User.pm <<'EOF'
package TaskDesk::Model::User;
use parent 'Yggdrasil::Model';
sub table      { 'users' }
sub timestamps { 0 }
1;
EOF

cat > lib/TaskDesk/Model/Task.pm <<'EOF'
package TaskDesk::Model::Task;
use parent 'Yggdrasil::Model';
sub table      { 'tasks' }
sub timestamps { 0 }
1;
EOF

cat > lib/TaskDesk/Resource/Task.pm <<'EOF'
package TaskDesk::Resource::Task;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Resource', -signatures;
use Mojolicious::Plugin::Skinir::Fields qw(ID Text Select);
use Mojolicious::Plugin::Skinir::Filter qw(SelectFilter);

sub model  { 'Task' }
sub title  { 'title' }
sub search { ['title'] }
sub policy { 'TaskDesk::Policy::Task' }

sub fields ($self, $c) {[
  ID(),
  Text('Title')->required->sortable->rules('max:150'),
  Select('Status')->required->default('open')
    ->options({open => 'Open', done => 'Done'}),
]}

sub filters ($self, $c) {[
  SelectFilter('Status', 'status', {open => 'Open', done => 'Done'}),
]}

sub csv_columns ($self, $c) { [qw(id title status)] }

1;
EOF

cat > lib/TaskDesk/Policy/Task.pm <<'EOF'
package TaskDesk::Policy::Task;
use Mojo::Base 'Mojolicious::Plugin::Skinir::Policy', -signatures;

sub _admin ($self, $c) {
  my $user = $c->skinir_user;
  return $user && ($user->get_attribute('role') // '') eq 'admin';
}

sub create ($self, $c, $task) { $self->_admin($c) }
sub update ($self, $c, $task) { $self->_admin($c) }
sub export ($self, $c, $task) { $self->_admin($c) }

1;
EOF

cat > script/init-db <<'EOF'
#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TaskDesk;

my $app = TaskDesk->new;
my $db = $app->db;
my $dbh = $db->dbh;
my $email = 'admin@example.test';

$db->transaction(sub {
  $dbh->do(q{
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      password TEXT NOT NULL,
      role TEXT NOT NULL
    )
  });
  $dbh->do(q{
    CREATE TABLE IF NOT EXISTS tasks (
      id INTEGER PRIMARY KEY,
      title TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('open', 'done'))
    )
  });
  my ($exists) = $dbh->selectrow_array('SELECT 1 FROM users WHERE email = ?', undef, $email);
  if ($exists) {
    print "Admin already exists. No password or records changed.\n";
    return;
  }
  my $password = $ENV{TASKDESK_ADMIN_PASSWORD} // '';
  die "Supply a password of 12 to 1024 characters\n"
    if length($password) < 12 || length($password) > 1024;
  my $hash = $app->skinir->hash_password($app->build_controller, $password);
  $dbh->do('INSERT INTO users (email, name, password, role) VALUES (?, ?, ?, ?)',
    undef, $email, 'Task Desk Admin', $hash, 'admin');
  $dbh->do('INSERT INTO tasks (title, status) VALUES (?, ?), (?, ?)', undef,
    'Write the project brief', 'open', 'Set up the repository', 'done');
  print "Created $email and two sample tasks.\n";
});
EOF
```

`TaskDesk.pm` makes the app and mounts Skinir. The models map the database tables, the resource describes the screen and CSV columns, and the policy grants individual abilities. Deletion is deliberately left disabled in this first app.

## Set up the database and sign in

Generate a local session secret, then choose your own admin password. The password below is read without echoing and is passed only to the setup command. The database stores its Argon2 hash.

```bash
export TASKDESK_SECRET="$(perl -MCrypt::URandom=urandom -e 'print unpack("H*", urandom(32))')"
read -rsp 'Choose a local admin password (at least 12 characters): ' TASKDESK_ADMIN_PASSWORD
printf '\n'
TASKDESK_ADMIN_PASSWORD="$TASKDESK_ADMIN_PASSWORD" perl script/init-db
unset TASKDESK_ADMIN_PASSWORD

perl script/taskdesk daemon -l http://127.0.0.1:3000
```

Open [Task Desk](http://127.0.0.1:3000/admin) and sign in as `admin@example.test` with the password you just chose. If you reopen the app in a new terminal, set the session secret again. Changing it invalidates existing sessions, but does not change your admin credentials or SQLite data.

## Verify your first workflow

1. Open **Tasks**. You should see two sample rows.
2. Choose **Create Task**, enter `Test the export`, leave the status as **Open**, and save it.
3. Return to **Tasks**, open **Filters**, and set **Status** to **Open**.
4. Click **Export CSV**. Open `tasks.csv` and check that it contains `ID`, `Title`, and `Status`, including `Test the export` but not `Set up the repository`.
5. Edit your test task and set its status to **Done**. It should no longer appear when filtering for **Open**.

Skinir exports all matching authorized rows across pages, not just the visible page or selected checkboxes. If the export exceeds 5,000 matched query rows or 5 MiB, narrow your filters and try again.

## If something does not work

| Symptom | Check |
|---|---|
| `Can't locate ... in @INC` | Run from `taskdesk/`, confirm `cpanm` succeeded, and set `PERL5LIB` again. |
| The login form opens, but sign-in fails | Run `perl script/init-db` successfully and use the password you chose. Rerunning setup does not reset an existing password. |
| The shell loads but does not show the admin interface | Skinir loads Vue from a CDN by default. Run `perl script/taskdesk skinir assets:vue`, add `vue => 'local'` to the Skinir config, and restart to serve it from your app. |
| **Export CSV** does not appear | The policy must grant `export`, and `csv_columns` must include at least one eligible field visible on the index. |

This setup is for local development. Before using it in production, use HTTPS and secure cookies, keep a stable session secret outside source control, replace setup SQL with migrations, and manage admin accounts through your application. The Skinir user guide covers the full resource, permission, and deployment configuration.
