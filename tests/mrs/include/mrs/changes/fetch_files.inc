if (!$mrs_sql_changes_variable)
{
  --let $mrs_sql_changes_variable=@file_changes
}

--disable_query_log
--disable_result_log

eval SET $mrs_sql_changes_variable=(
           SELECT IF(v is NULL,NULL,v+0) FROM (SELECT JSON_UNQUOTE(JSON_EXTRACT(details,"$.changesFiles")) as v
           FROM mariadb_rest_service.rest_daemon_status
           ORDER BY id DESC LIMIT 0,1)as sub);

--enable_query_log
--enable_result_log

--let $mrs_schema_id_sql_variable=
--let $mrs_sql_changes_variable=
--let $mrs_do_not_wait_at_fetch=
