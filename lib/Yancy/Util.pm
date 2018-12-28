package Yancy::Util;
our $VERSION = '1.023';
# ABSTRACT: Utilities for Yancy

=head1 SYNOPSIS

    use Yancy::Util qw( load_backend );
    my $be = load_backend( 'test://localhost', $collections );

    use Yancy::Util qw( curry );
    my $helper = curry( \&_helper_sub, @args );

    use Yancy::Util qw( currym );
    my $sub = currym( $object, 'method_name', @args );

=head1 DESCRIPTION

This module contains utility functions for Yancy.

=head1 SEE ALSO

L<Yancy>

=cut

use Mojo::Base '-strict';
use Exporter 'import';
use Mojo::Loader qw( load_class );
use Scalar::Util qw( blessed );
use Math::BigInt;
our @EXPORT_OK = qw( load_backend curry currym defs2mask );

=sub load_backend

    my $backend = load_backend( $backend_url, $collections );
    my $backend = load_backend( { $backend_name => $arg }, $collections );

Get a Yancy backend from the given backend URL, or from a hash reference
with a backend name and optional argument. The C<$collections> hash is
the configured collections for this backend.

A backend URL should begin with a name followed by a colon. The first
letter of the name will be capitalized, and used to build a class name
in the C<Yancy::Backend> namespace.

The C<$backend_name> should be the name of a module in the
C<Yancy::Backend> namespace. The C<$arg> is handled by the backend
module. Read your backend module's documentation for details.

See L<Yancy::Help::Config/Database Backend> for information about
backend URLs and L<Yancy::Backend> for more information about backend
objects.

=cut

sub load_backend {
    my ( $config, $collections ) = @_;
    my ( $type, $arg );
    if ( !ref $config ) {
        ( $type ) = $config =~ m{^([^:]+)};
        $arg = $config
    }
    else {
        ( $type, $arg ) = %{ $config };
    }
    my $class = 'Yancy::Backend::' . ucfirst $type;
    if ( my $e = load_class( $class ) ) {
        die ref $e ? "Could not load class $class: $e" : "Could not find class $class";
    }
    return $class->new( $arg, $collections );
}

=sub curry

    my $curried_sub = curry( $sub, @args );

Return a new subref that, when called, will call the passed-in subref with
the passed-in C<@args> first.

For example:

    my $add = sub {
        my ( $lop, $rop ) = @_;
        return $lop + $rop;
    };
    my $add_four = curry( $add, 4 );
    say $add_four->( 1 ); # 5
    say $add_four->( 2 ); # 6
    say $add_four->( 3 ); # 7

This is more-accurately called L<partial
application|https://en.wikipedia.org/wiki/Partial_application>, but
C<curry> is shorter.

=cut

sub curry {
    my ( $sub, @args ) = @_;
    return sub { $sub->( @args, @_ ) };
}

=sub currym

    my $curried_sub = currym( $obj, $method, @args );

Return a subref that, when called, will call given C<$method> on the
given C<$obj> with any passed-in C<@args> first.

See L</curry> for an example.

=cut

sub currym {
    my ( $obj, $meth, @args ) = @_;
    my $sub = $obj->can( $meth )
        || die sprintf q{Can't curry method "%s" on object of type "%s": Method is not implemented},
            $meth, blessed( $obj );
    return curry( $sub, $obj, @args );
}

=sub defs2mask

Given a hashref that is the C<definitions> of an OpenAPI spec, returns a
hashref that maps each definition name to a bitmask. The bitmask is set
from each property name in that definition, according to its order in
the complete sorted list of all property names in the definitions. Not
exported. E.g.

  # properties:
  my $defs = {
    d1 => {
      properties => {
        p1 => 'string',
        p2 => 'string',
      },
    },
    d2 => {
      properties => {
        p2 => 'string',
        p3 => 'string',
      },
    },
  };
  my $mask = defs2mask($defs);
  # all prop names, sorted: qw(p1 p2 p3)
  # $mask:
  {
    d1 => (1 << 0) | (1 << 1),
    d2 => (1 << 1) | (1 << 2),
  }

=cut

# sorted list of all propnames
sub _get_all_propnames {
  my ($defs) = @_;
  my %allprops;
  for my $defname (keys %$defs) {
    $allprops{$_} = 1 for keys %{ $defs->{$defname}{properties} };
  }
  [ sort keys %allprops ];
}

sub defs2mask {
  my ($defs) = @_;
  my $allpropnames = _get_all_propnames($defs);
  my $count = 0;
  my %prop2count;
  for my $propname (@$allpropnames) {
    $prop2count{$propname} = $count;
    $count++;
  }
  my %def2mask;
  for my $defname (keys %$defs) {
    $def2mask{$defname} ||= Math::BigInt->new(0);
    $def2mask{$defname} |= (Math::BigInt->new(1) << $prop2count{$_})
      for keys %{ $defs->{$defname}{properties} };
  }
  \%def2mask;
}

1;
