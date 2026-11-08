# Minimal stand-ins so the pure logic of fields/filters/metrics can be tested without a database.
package Fake::Model;
sub new { my ($c, %a) = @_; bless {attrs => {%a}, stored => 0, casts => {}}, $c }
sub get_attribute { $_[0]{attrs}{$_[1]} }
sub set_attribute { $_[0]{attrs}{$_[1]} = $_[2]; $_[0] }
sub in_storage    { $_[0]{stored} }
sub casts         { $_[0]{casts} }

package Fake::Class;
sub table       { 'items' }
sub primary_key { 'id' }

package Fake::Skinir;
sub new          { bless {}, shift }
sub field_label  { $_[3]->label }
sub tr_or        { $_[3] }
sub upload_url   { "/uploads/$_[1]" }

package Fake::C;
sub new    { bless {skinir => Fake::Skinir->new, params => {}}, shift }
sub skinir { $_[0]{skinir} }

package Fake::Resource;
sub new       { bless {}, shift }
sub uri_key   { 'items' }

package Fake::Query;
sub new   { bless {calls => []}, shift }
sub where { my $s = shift; push @{$s->{calls}}, ['where', @_]; $s }
sub calls { $_[0]{calls} }

1;
