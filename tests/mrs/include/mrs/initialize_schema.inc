# ==== Purpose ====
#
# Create valid MySQL Rest Service schema.
#
# ==== Usage ====
#
# --source ../include/mrs_initialize_schema.inc
#

--disable_query_log
--disable_result_log

--source ./check_mrs_schema_version.inc

if ($mrs_schema_version == 5)
{
  # MariaDB Shell's deployment script 5.0.0 (tools/analysis/make_test_schema.py)
  --source ../schema/mariadb_rest_service-5.0.0.sql
  --let $_mrs_schema_version_supported=1
}


if (!$_mrs_schema_version_supported)
{
  --die MRS test-suite executed with unsupported schema version $mrs_schema_version.
}

UPDATE mariadb_rest_service.config SET data = JSON_MERGE_PATCH(data, '{"sqlQuery":{"timeout":60000}}');

--enable_query_log
--enable_result_log

echo # MySQL Rest Service schema created.;
