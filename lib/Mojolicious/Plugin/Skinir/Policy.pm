package Mojolicious::Plugin::Skinir::Policy;
use Mojo::Base -base, -signatures;

# Default policy: any authenticated panel user may do everything.
# Subclass it and override only what you need:
#
#   package MyApp::Policy::Post;
#   use Mojo::Base 'Mojolicious::Plugin::Skinir::Policy', -signatures;
#   sub delete ($self, $c, $post) { $c->skinir_user->role eq 'admin' }
#
# Each method receives ($self, $c, $model) and returns true to allow.
# view_any / create receive a blank model instance.

sub _signed_in ($self, $c) { $c->skinir_user ? 1 : 0 }

sub view_any     ($self, $c, $m) { $self->_signed_in($c) }
sub view         ($self, $c, $m) { $self->_signed_in($c) }
sub create       ($self, $c, $m) { $self->_signed_in($c) }
sub update       ($self, $c, $m) { $self->_signed_in($c) }
sub delete       ($self, $c, $m) { $self->_signed_in($c) }
sub restore      ($self, $c, $m) { $self->_signed_in($c) }
sub force_delete ($self, $c, $m) { $self->_signed_in($c) }

1;
