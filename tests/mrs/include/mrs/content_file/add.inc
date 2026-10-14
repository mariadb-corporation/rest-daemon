if (!$mrs_content_set_id_sql_variable)
{
  --let $mrs_content_set_id_sql_variable=@content_set_id
}

if (!$mrs_sql_id_variable)
{
  --let $mrs_sql_id_variable=@content_file_id
}

if (!$mrs_add_content_file_path)
{
  --die 'mrs_add_content_file_path' variable is required.
}

if (!$mrs_add_content)
{
  --die 'mrs_add_content' variable is required.
}

if (!$mrs_add_content_file_auth)
{
  --let $mrs_add_content_file_auth=DEFAULT
}

--disable_query_log
--disable_result_log
eval SET $mrs_sql_id_variable=mariadb_rest_service.get_sequence_id();
eval  INSERT INTO mariadb_rest_service.content_file(
               id, content_set_id, request_path,
               requires_auth, content $mrs_add_content_custom_fields)
      VALUES($mrs_sql_id_variable,  $mrs_content_set_id_sql_variable,
             "$mrs_add_content_file_path",
             $mrs_add_content_file_auth,
             $mrs_add_content
             $mrs_add_content_custom_values);

--let $_path=`SELECT CONCAT(s.url_context_root, db.request_path, o.request_path) FROM mariadb_rest_service.content_file as o JOIN mariadb_rest_service.content_set as db on db.id=o.content_set_id JOIN mariadb_rest_service.service as s ON  s.id = db.service_id  WHERE o.id=$mrs_sql_id_variable;`
--echo # Registred CONTENT_FILE at path: $_path

--enable_query_log
--enable_result_log

--inc $_mrs_files_definitions

--let $mrs_content_set_id_sql_variable=
--let $mrs_sql_id_variable_ob=
--let $mrs_sql_id_variable=
--let $mrs_add_content_file_path=
--let $mrs_add_content_file_auth=
--let $mrs_add_content=
--let $mrs_add_content_custom_values=
--let $mrs_add_content_custom_fields=

