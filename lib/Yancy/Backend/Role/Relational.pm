package Yancy::Backend::Role::Relational;
our $VERSION = '1.025';
# ABSTRACT: A role to give a relational backend relational capabilities

=head1 SYNOPSIS

    package Yancy::Backend::RDBMS;
    with 'Yancy::Backend::Role::Relational';

=head1 DESCRIPTION

This role implements utility methods to make backend classes work with
entity relations, using L<DBI> methods such as
C<DBI/foreign_key_info>.

=head1 REQUIRED METHODS

The composing class must implement the following:

=head2 mojodb

The value must be a relative of L<Mojo::Pg> et al.

=head2 mojodb_class

String naming the C<Mojo::*> class.

=head2 mojodb_prefix

String with the value at the start of a L<DBI> C<dsn>.

=head2 mojodb_abstract

An L<SQL::Abstract::Pg> or subclass. Must set C<name_sep> and
C<quote_char> correctly.

=head2 filter_table

Called with a table name, returns a boolean of true to keep, false
to discard - typically for a system table.

=head2 fixup_default

Called with a column's default value, returns the corrected version,
which if C<undef> means no default.

=head2 column_info_extra

Called with a table-name, and the array-ref returned by
L<DBI/column_info>, returns a hash-ref mapping column names to an "extra
info" hash for that column, with possible keys:

=over

=item auto_increment

a boolean

=item enum

an array-ref of allowed values

=back

=head2 dbcatalog

Returns the L<DBI> "catalog" argument for e.g. L<DBI/column_info>.

=head2 dbschema

Returns the L<DBI> "schema" argument for e.g. L<DBI/column_info>.

=head1 METHODS

=head2 new

Self-explanatory, implements L<Yancy::Backend/new>.

=head2 id_field

Given a collection, returns the string name of its ID field.

=head2 pk_field

Given a collection, returns the string name of its numerical primary-key,
possibly "surrogate" (an integer, for efficiency) field. If no PK is
available, will return the unique column-name.

=head2 list_sqls

Given a collection, parameters and options, returns SQL to generate the
actual results, the count results, and the bind-parameters.

=head2 normalize

Given a collection and data, normalises any boolean values to 1 and 0.

=head2 delete

Self-explanatory, implements L<Yancy::Backend/delete>.

=head2 set

Self-explanatory, implements L<Yancy::Backend/set>.

=head2 get

Self-explanatory, implements L<Yancy::Backend/get>.

=head2 list

Self-explanatory, implements L<Yancy::Backend/list>.

=head2 read_schema

Implements L<Yancy::Backend/read_schema>.

Understands foreign key relationships, and uses them to include properties
that are C<$ref> links to other collections. A heuristic is used to name
the property based on the foreign-key column name.

=head1 SEE ALSO

L<Yancy::Backend>

=cut

use Mojo::Base '-role';
use Scalar::Util qw( blessed looks_like_number );
use Mojo::JSON qw( true encode_json );
use Carp qw( croak );
use Yancy::Util qw( copy_inline_refs );
use SQL::Abstract::Prefetch;

has 'prefetch';

use DBI ':sql_types';
# only specify non-string - code-ref called with column_info row
my $maybe_boolean = sub {
    # how mysql does BOOLEAN - not a TINYINT, but INTEGER
    my ( $c ) = @_;
    ( ( $c->{mysql_type_name} // '' ) eq 'tinyint(1)' )
        ? { type => 'boolean' }
        : { type => 'integer' };
};
my %SQL2OAPITYPE = (
    SQL_BIGINT() => { type => 'integer' },
    SQL_BIT() => { type => 'boolean' },
    SQL_TINYINT() => $maybe_boolean,
    SQL_NUMERIC() => { type => 'number' },
    SQL_DECIMAL() => { type => 'number' },
    SQL_INTEGER() => $maybe_boolean,
    SQL_SMALLINT() => { type => 'integer' },
    SQL_FLOAT() => { type => 'number' },
    SQL_REAL() => { type => 'number' },
    SQL_DOUBLE() => { type => 'number' },
    SQL_DATETIME() => { type => 'string', format => 'date-time' },
    SQL_DATE() => { type => 'string', format => 'date' },
    SQL_TIME() => { type => 'string', format => 'date-time' },
    SQL_TIMESTAMP() => { type => 'string', format => 'date-time' },
    SQL_BOOLEAN() => { type => 'boolean' },
    SQL_TYPE_DATE() => { type => 'string', format => 'date' },
    SQL_TYPE_TIME() => { type => 'string', format => 'date-time' },
    SQL_TYPE_TIMESTAMP() => { type => 'string', format => 'date-time' },
    SQL_TYPE_TIME_WITH_TIMEZONE() => { type => 'string', format => 'date-time' },
    SQL_TYPE_TIMESTAMP_WITH_TIMEZONE() => { type => 'string', format => 'date-time' },
    SQL_LONGVARBINARY() => { type => 'string', format => 'binary' },
    SQL_VARBINARY() => { type => 'string', format => 'binary' },
    SQL_BINARY() => { type => 'string', format => 'binary' },
    SQL_BLOB() => { type => 'string', format => 'binary' },
);
# SQLite fallback
my %SQL2TYPENAME = (
    SQL_BOOLEAN() => [ qw(boolean) ],
    SQL_INTEGER() => [ qw(int integer smallint bigint tinyint rowid) ],
    SQL_REAL() => [ qw(double float money numeric real) ],
    SQL_TYPE_TIMESTAMP() => [ qw(timestamp datetime) ],
    SQL_BLOB() => [ qw(blob) ],
);
my %TYPENAME2SQL = map {
    my $sql = $_;
    map { $_ => $sql } @{ $SQL2TYPENAME{ $sql } };
} keys %SQL2TYPENAME;
my %IGNORE_TABLE = (
    mojo_migrations => 1,
    minion_jobs => 1,
    minion_workers => 1,
    minion_locks => 1,
    mojo_pubsub_listener => 1,
    mojo_pubsub_listen => 1,
    mojo_pubsub_notify => 1,
    mojo_pubsub_queue => 1,
    dbix_class_schema_versions => 1,
);

requires qw(
    mojodb mojodb_class mojodb_prefix mojodb_abstract
    dbcatalog dbschema
    filter_table fixup_default column_info_extra
);

sub new {
    my ( $class, $backend, $collections ) = @_;
    my %attr = ( abstract => $class->mojodb_abstract );
    if ( !ref $backend ) {
        my $found = (my $connect = $backend) =~ s#^.*?:##;
        $backend = $class->mojodb_class->new( $found ? $class->mojodb_prefix.":$connect" : () );
    }
    elsif ( !blessed $backend ) {
        %attr = ( %attr, %$backend );
        $backend = $class->mojodb_class->new;
    }
    for my $method ( keys %attr ) {
        $backend->$method( $attr{ $method } );
    }
    my %vars = (
        mojodb => $backend,
        collections => $collections,
    );
    my $self = Mojo::Base::new( $class, %vars );
    $self->{prefetch} = SQL::Abstract::Prefetch->new(
        abstract => $self->mojodb_abstract,
        dbhgetter => sub { $self->mojodb->db->dbh },
        dbcatalog => $self->dbcatalog,
        dbschema => $self->dbschema,
        filter_table => sub { $class->filter_table( @_ ) },
    );
    $self;
}

sub id_field {
    my ( $self, $coll ) = @_;
    return $self->collections->{ $coll }{ 'x-id-field' } || 'id';
}

sub pk_field {
    my ( $self, $coll ) = @_;
    return $self->collections->{ $coll }{ 'x-pk-field' } || 'id';
}

sub list_sqls {
    my ( $self, $coll, $params, $opt ) = @_;
    my $mojodb = $self->mojodb;
    my $schema = $self->collections->{ $coll };
    my $real_coll = ( $schema->{'x-view'} || {} )->{collection} // $coll;
    my $props = $schema->{properties}
        || $self->collections->{ $real_coll }{properties};
    my ( $query, @params ) = $mojodb->abstract->select(
        $real_coll,
        [ grep !$props->{ $_ }{'$ref'}, keys %$props ],
        $params,
        $opt->{order_by},
    );
    my ( $total_query, @total_params ) = $mojodb->abstract->select(
        $real_coll,
        [ \'COUNT(*) as total' ],
        $params,
    );
    if ( scalar grep defined, @{ $opt }{qw( limit offset )} ) {
        die "Limit must be number" if $opt->{limit} && !looks_like_number $opt->{limit};
        $query .= ' LIMIT ' . ( $opt->{limit} // 2**32 );
        if ( $opt->{offset} ) {
            die "Offset must be number" if !looks_like_number $opt->{offset};
            $query .= ' OFFSET ' . $opt->{offset};
        }
    }
    #; say $query;
    return ( $query, $total_query, @params );
}

sub normalize {
    my ( $self, $coll, $data ) = @_;
    return undef if !$data;
    my $schema = $self->collections->{ $coll }{ properties };
    my %replace;
    for my $key ( keys %$data ) {
        next if !defined $data->{ $key }; # leave nulls alone
        my $type = $schema->{ $key }{ type };
        next if !_is_type( $type, 'boolean' );
        # Boolean: true (1, "true"), false (0, "false")
        $replace{ $key }
            = $data->{ $key } && $data->{ $key } !~ /^false$/i
            ? 1 : 0;
    }
    +{ %$data, %replace };
}

sub _is_type {
    my ( $type, $is_type ) = @_;
    return unless $type;
    return ref $type eq 'ARRAY'
        ? !!grep { $_ eq $is_type } @$type
        : $type eq $is_type;
}

sub delete {
    my ( $self, $coll, $id ) = @_;
    my $id_field = $self->id_field( $coll );
    my $ret = eval { $self->mojodb->db->delete( $coll, { $id_field => $id } )->rows };
    croak "Error on delete '$coll'=$id: $@" if $@;
    return !!$ret;
}

sub set {
    my ( $self, $coll, $id, $params ) = @_;
    $params = $self->normalize( $coll, $params );
    die "No refs allowed in '$coll'($id): " . encode_json $params
        if grep ref, values %$params;
    my $id_field = $self->id_field( $coll );
    my $ret = eval { $self->mojodb->db->update( $coll, $params, { $id_field => $id } )->rows };
    croak "Error on set '$coll'=$id: $@" if $@;
    return !!$ret;
}

sub get {
    my ( $self, $coll, $id ) = @_;
    my $id_field = $self->id_field( $coll );
    my $schema = $self->collections->{ $coll };
    my $real_coll = ( $schema->{'x-view'} || {} )->{collection} // $coll;
    my $props = $schema->{properties}
        || $self->collections->{ $real_coll }{properties};
    my $ret = $self->mojodb->db->select(
        $real_coll,
        [ grep !$props->{ $_ }{'$ref'}, keys %$props ],
        { $id_field => $id },
    )->hash;
    return $self->normalize( $coll, $ret );
}

sub list {
    my ( $self, $coll, $params, $opt ) = @_;
    $params ||= {}; $opt ||= {};
    my $mojodb = $self->mojodb;
    my ( $query, $total_query, @params ) = $self->list_sqls( $coll, $params, $opt );
    my $items = $mojodb->db->query( $query, @params )->hashes;
    return {
        items => [ map $self->normalize( $coll, $_ ), @$items ],
        total => $mojodb->db->query( $total_query, @params )->hash->{total},
    };
}

sub read_schema {
    my ( $self, @table_names ) = @_;
    my %schema;
    my $db = $self->mojodb->db;
    my ( $dbcatalog, $dbschema ) = ( scalar $self->dbcatalog, scalar $self->dbschema );
    my @all_tables = grep $self->filter_table($_), map $_->{TABLE_NAME}, @{ $db->dbh->table_info(
        $dbcatalog, $dbschema, undef, 'TABLE'
    )->fetchall_arrayref( { TABLE_NAME => 1 } ) };
    s/\W//g for @all_tables; # PostgreSQL quotes "user"
    for my $table ( @all_tables ) {
        # ; say "Got table $table";
        $schema{ $table }{type} = 'object';
        my $stats_info = $db->dbh->statistics_info(
            $dbcatalog, $dbschema, $table, 1, 1
        )->fetchall_arrayref( {} );
        my $columns = $db->dbh->column_info( $dbcatalog, $dbschema, $table, undef )->fetchall_arrayref( {} );
        my %is_pk = map {$_=>1} $db->dbh->primary_key( $dbcatalog, $dbschema, $table );
        my @unique_columns = grep !$is_pk{ $_ },
            map $_->{COLUMN_NAME},
            grep !$_->{NON_UNIQUE}, # mysql
            @$stats_info;
        my $col2info = $self->column_info_extra( $table, $columns );
        # ; say "Got columns";
        # ; use Data::Dumper;
        # ; say Dumper $columns;
        for my $c ( @$columns ) {
            my $column = $c->{COLUMN_NAME};
            my %info = %{ $col2info->{ $column } || {} };
            # the || is because SQLite doesn't give the DATA_TYPE
            my $sqltype = $c->{DATA_TYPE} || $TYPENAME2SQL{ lc $c->{TYPE_NAME} };
            my $typeref = $SQL2OAPITYPE{ $sqltype || '' } || { type => 'string' };
            $typeref = $typeref->( $c ) if ref $typeref eq 'CODE';
            my %oapitype = %$typeref;
            if ( !$is_pk{ $column } && $c->{NULLABLE} ) {
                $oapitype{ type } = [ $oapitype{ type }, 'null' ];
            }
            my $auto_increment = delete $info{auto_increment};
            my $default = $self->fixup_default( $c->{COLUMN_DEF} );
            if ( defined $default ) {
                $oapitype{ default } = $default;
            }
            $oapitype{readOnly} = true if $auto_increment;
            $schema{ $table }{ properties }{ $column } = {
                %info,
                %oapitype,
                'x-order' => $c->{ORDINAL_POSITION},
            };
            if ( ( !$c->{NULLABLE} || $is_pk{ $column } ) && !$auto_increment && !defined $default ) {
                push @{ $schema{ $table }{ required } }, $column;
            }
        }
        my ( $pk ) = keys %is_pk;
        if ( @unique_columns == 1 and $unique_columns[0] ne 'id' ) {
            # favour "natural" key over "surrogate" integer one, if exists
            $schema{ $table }{ 'x-id-field' } = $unique_columns[0];
        }
        elsif ( $pk && $pk ne 'id' ) {
            $schema{ $table }{ 'x-id-field' } = $pk;
        }
        if ( $pk && $pk ne 'id' ) {
            $schema{ $table }{ 'x-pk-field' } = $pk;
        }
        elsif ( !$pk && @unique_columns == 1 && $unique_columns[0] ne 'id' ) {
            $schema{ $table }{ 'x-pk-field' } = $unique_columns[0];
        }
        if ( $IGNORE_TABLE{ $table } ) {
            $schema{ $table }{ 'x-ignore' } = 1;
        }
    }
    for my $table ( @all_tables ) {
        my $fkall = $self->prefetch->dbspec->{ $table };
        for my $fromlabel ( keys %$fkall ) {
            my $fkinfo = $fkall->{ $fromlabel };
            next if $fkinfo->{type} ne 'single';
            my $to = $fkinfo->{totable};
            $schema{ $table }{properties}{ $fromlabel } = { '$ref' => "#/$to" };
        }
    }
    my @ret = @table_names
        ? map copy_inline_refs( \%schema, "/$_" ), @table_names
        : \%schema;
    if ( !wantarray ) {
        croak "Scalar context but >1 return value" if @ret > 1;
        return $ret[0];
    }
    @ret;
}

1;
