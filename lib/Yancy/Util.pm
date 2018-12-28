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
our @EXPORT_OK = qw( load_backend curry currym defs2mask definitions_non_fundamental );

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

=sub definitions_non_fundamental

Given the C<definitions> of an OpenAPI spec, will return a hash-ref
mapping names of definitions considered non-fundamental to a
value. The value is either the name of another definition that I<is>
fundamental, or or C<undef> if it just contains e.g. a string. It will
instead be a reference to such a value if it is to an array of such.

This may be used e.g. to determine the "real" input or output of an
OpenAPI operation.

Non-fundamental is determined according to these heuristics:

=over

=item *

object definitions with key C<x-is-really> are "really" that value

=item *

object definitions that only have one property (which the author calls
"thin objects"), or that have two properties, one of whose names has
the substring "count" (case-insensitive).

=item *

object definitions that have all the same properties as another, and
are not the shortest-named one between the two.

=item *

object definitions whose properties are a strict subset of another.

=back

=cut

# heuristic 0: strip out "x-is-really"
sub _strip_is_really {
  my ($defs) = @_;
  my %other2real = map {
    $_ => $defs->{$_}{'x-is-really'}
  } grep $defs->{$_}{'x-is-really'}, keys %$defs;
  \%other2real;
}

# heuristic 1: strip out single-item objects - RHS = ref if array
sub _strip_thin {
  my ($defs, $other2real) = @_;
  my %thin2real = map {
    my $theseprops = $defs->{$_}{properties};
    my @props = grep !/count/i, keys %$theseprops;
    my $real = @props == 1 ? $theseprops->{$props[0]} : undef;
    my $is_array = $real = $real->{items}
      if $real and ($real->{type} // '') eq 'array';
    $real = $real->{'$ref'} if $real;
    $real = _ref2def($real) if $real;
    @props == 1 ? ($_ => $is_array ? \$real : $real) : ()
  } grep !$other2real->{$_}, keys %$defs;
  \%thin2real;
}

# heuristic 2: find objects with same propnames, drop those with longer names
sub _strip_dup {
  my ($defs, $def2mask, $reffed, $other2real) = @_;
  my %sig2names;
  push @{ $sig2names{$def2mask->{$_}} }, $_ for keys %$def2mask;
  my @nondups = grep @{ $sig2names{$_} } == 1, keys %sig2names;
  delete @sig2names{@nondups};
  my %dup2real;
  for my $sig (keys %sig2names) {
    next if grep $other2real->{$_} || $reffed->{$_}, @{ $sig2names{$sig} };
    my @names = sort { (length $a <=> length $b) } @{ $sig2names{$sig} };
    my $real = shift @names; # keep the first i.e. shortest
    $dup2real{$_} = $real for @names;
  }
  \%dup2real;
}

# heuristic 3: find objects with set of propnames that is subset of
#   another object's propnames
sub _strip_subset {
  my ($defs, $def2mask, $reffed, $other2real) = @_;
  my %subset2real;
  for my $defname (keys %$defs) {
    next if $reffed->{$defname} or $other2real->{$defname};
    my $thismask = $def2mask->{$defname};
    for my $supersetname (grep $_ ne $defname, keys %$defs) {
      my $supermask = $def2mask->{$supersetname};
      next if $thismask == $supermask;
      next unless ($thismask & $supermask) == $thismask;
      $subset2real{$defname} = $supersetname;
    }
  }
  \%subset2real;
}

sub _maybe_deref { ref($_[0]) ? ${$_[0]} : $_[0] }

sub _map_thru {
  my ($x2y) = @_;
  my %mapped = %$x2y;
  for my $fake (keys %mapped) {
    my $real = $mapped{$fake};
    next if !_maybe_deref $real;
    $mapped{$_} = (ref $mapped{$_} ? \$real : $real) for
      grep $fake eq _maybe_deref($mapped{$_}),
      grep _maybe_deref($mapped{$_}),
      keys %mapped;
  }
  \%mapped;
}

sub _ref2def {
  my ($ref) = @_;
  $ref =~ s:^#/definitions/:: or return;
  $ref;
}

sub _find_referenced {
  my ($defs, $thin2real) = @_;
  my %reffed;
  for my $defname (grep !$thin2real->{$_}, keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    for my $propname (keys %$theseprops) {
      if (my $ref = $theseprops->{$propname}{'$ref'}
        || ($theseprops->{$propname}{items} && $theseprops->{$propname}{items}{'$ref'})
      ) {
        $reffed{ _ref2def($ref) } = 1;
      }
    }
  }
  \%reffed;
}

sub definitions_non_fundamental {
  my ($defs) = @_;
  my $other2real = _strip_is_really($defs);
  my $thin2real = _strip_thin($defs, $other2real);
  my $def2mask = defs2mask($defs);
  my $reffed = _find_referenced($defs, $thin2real);
  my $dup2real = _strip_dup($defs, $def2mask, $reffed, $other2real);
  my $subset2real = _strip_subset($defs, $def2mask, $reffed, $other2real);
  _map_thru({ %$other2real, %$thin2real, %$dup2real, %$subset2real });
}

1;
