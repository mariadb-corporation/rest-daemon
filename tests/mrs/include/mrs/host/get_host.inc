

if (!$mrs_add_host_name)
{
  --die 'mrs_get_host_name' variable is required.
}

--disable_query_log
--disable_result_log

if (`SELECT 1 FROM mariadb_rest_service.url_host WHERE name like $mrs_get_host_name`)
{
--let $mrs_host_id=`SELECT id FROM mariadb_rest_service.url_host WHERE name like $mrs_get_host_name`
}
--enable_query_log
--enable_result_log

--let $mrs_get_host_name=
