--source ./check_mrs_schema_version.inc

if ($mrs_schema_version!=5)
{
  --skip Test specific for mrs-metadata-schema version '5', but found '$mrs_schema_version'
}
