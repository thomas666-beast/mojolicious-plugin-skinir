use strict;
use warnings;
use Test::More;

use Mojolicious::Plugin::Skinir::Resource;

{ package T::Resource::BlogPost;  our @ISA = ('Mojolicious::Plugin::Skinir::Resource'); sub model { 'BlogPost' } }
{ package T::Resource::User;      our @ISA = ('Mojolicious::Plugin::Skinir::Resource'); sub model { 'User' } }
{ package T::Resource::Category;  our @ISA = ('Mojolicious::Plugin::Skinir::Resource'); sub model { 'Category' } }
{ package T::Resource::Address;   our @ISA = ('Mojolicious::Plugin::Skinir::Resource'); sub model { 'Address' } }
{ package T::Resource::Empty;     our @ISA = ('Mojolicious::Plugin::Skinir::Resource'); }

is(T::Resource::User->new->uri_key,      'users',       'uri key');
is(T::Resource::BlogPost->new->uri_key,  'blog-posts',  'multi-word uri key');
is(T::Resource::Category->new->uri_key,  'categories',  'y => ies');
is(T::Resource::Address->new->uri_key,   'addresses',   'ss => sses');

is(T::Resource::BlogPost->new->label,          'Blog Posts', 'label');
is(T::Resource::BlogPost->new->singular_label, 'Blog Post',  'singular label');
is(T::Resource::Category->new->label,          'Categories', 'label plural');

is(T::Resource::User->new->title, 'id', 'default title column');
is_deeply(T::Resource::User->new->search, [], 'no search columns by default');
is(T::Resource::User->new->per_page, 25, 'default page size');

{
  package Fake::M; sub new { bless {n => $_[1]}, $_[0] } sub get_attribute { $_[0]{n}{$_[1]} } sub get_key { $_[0]{n}{id} }
}
{ package T::Resource::Named; our @ISA = ('Mojolicious::Plugin::Skinir::Resource'); sub title { 'name' } }
is(T::Resource::Named->new->title_of(Fake::M->new({id => 3, name => 'Ann'})), 'Ann', 'title_of column');
is(T::Resource::Named->new->title_of(Fake::M->new({id => 3})), '#3', 'title_of falls back to the key');
{ package T::Resource::Code; our @ISA = ('Mojolicious::Plugin::Skinir::Resource'); sub title { sub { uc $_[0]->get_attribute('name') } } }
is(T::Resource::Code->new->title_of(Fake::M->new({id => 3, name => 'ann'})), 'ANN', 'title as coderef');

eval { T::Resource::Empty->new->model };
like $@, qr/model\(\) must return/, 'model() must be overridden';

done_testing;
