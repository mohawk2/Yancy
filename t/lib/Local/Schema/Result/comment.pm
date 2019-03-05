use utf8;
package Local::Schema::Result::comment;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Core';
__PACKAGE__->table("comment");
__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "comment_id_seq",
  },
  "user_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "blog_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "markdown",
  { data_type => "text", is_nullable => 0 },
  "html",
  { data_type => "text", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("id");
__PACKAGE__->belongs_to(
  "blog",
  "Local::Schema::Result::blog",
  { id => "blog_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "user",
  "Local::Schema::Result::user",
  { id => "user_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-02-24 06:06:19
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:A15nYtQ6ggmt4E8l+meltQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
