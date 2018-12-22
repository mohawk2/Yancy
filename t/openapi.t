
=head1 DESCRIPTION

This test ensures that Yancy's linking up of a supplied OpenAPI spec to
API controllers works as expected.

=head1 SEE ALSO

L<Yancy::Backend::Test>

=cut

use Mojo::Base '-strict';
use Test::More;
use Test::Mojo;
use Mojo::JSON qw( from_json );
use FindBin qw( $Bin );
use Mojo::File qw( path );

BEGIN {
    eval { require Mojo::SQLite; Mojo::SQLite->VERSION( 3 ); 1 }
        or plan skip_all => 'Mojo::SQLite >= 3.0 required for this test';
}

use lib "".path( $Bin, 'lib' );
use Local::Test qw( init_backend );
use Mojo::SQLite;
use Mojo::URL;
use File::Temp;

my $rwpath = path( $Bin, qw(share realworld) );
my $tempdir = File::Temp->newdir; # Deleted when object goes out of scope
my $tempfile = path( $tempdir )->child( 'test.db' );
$ENV{TEST_YANCY_BACKEND} = "".Mojo::URL->new->scheme('sqlite')->path($tempfile);
{
my $sqlite = Mojo::SQLite->new( $ENV{TEST_YANCY_BACKEND} );
my $db = $sqlite->db;
my $ddl = $rwpath->child( 'schema.sqlite' )->slurp;
my $tx = $db->begin;
$db->query($_) for split /\n{2,}/, $ddl;
$tx->commit;
#diag explain $db->query('select * from sqlite_master')->text;
}

$ENV{MOJO_HOME} = $rwpath;
my ( $backend_url, $backend, %items ) = init_backend(
    {
        "Article" => { "x-id-field" => "slug" },
    },
    User => [
        {
            username => 'joel',
            email => 'joel@example.com',
            password_hash => 'ignore',
            bio => 'joel bio',
            image => 'none',
        },
        {
            username => 'bigme',
            email => 'me@example.com',
            password_hash => 'pwh',
            bio => 'my bio',
            image => 'none',
        }
    ],
);
#diag $backend_url;

subtest 'with openapi spec AND overlay files' => sub {
    my $t = Test::Mojo->new( 'Yancy', {
        backend => $backend_url,
        openapi => 'realworld-spec.json',
        openapi_overlay => 'realworld-spec.json.overlay',
    } );
    $t->get_ok( '/yancy/api' )
      ->status_is( 200 )
      ;
};

done_testing;
