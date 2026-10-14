# mariadb-restd --setup against the test server
#
# $setup_name_cmd: optional, e.g. --name MyName

--source ../include/mrs/initialize_schema.inc

# an account with only the privileges --setup needs
CREATE USER mrs_setup_user IDENTIFIED BY 'pass';
GRANT SELECT, INSERT, UPDATE on mariadb_rest_service.* to mrs_setup_user;
GRANT mariadb_rest_service_data_provider TO mrs_setup_user WITH ADMIN OPTION;
GRANT CREATE USER ON *.* TO mrs_setup_user WITH GRANT OPTION;
GRANT mariadb_rest_service_meta_provider TO mrs_setup_user WITH ADMIN OPTION;

--source setup_mrs_replace.inc
exec $MYSQLROUTER --setup mrs_setup_user:pass@127.0.0.1:$MASTER_MYPORT
   -d $MYSQL_TMP_DIR/setup_folder
   $setup_name_cmd
   --conf-set-option=DEFAULT.plugin_folder=$ROUTER_PLUGIN_DIRECTORY
   --jwt-secret something_important;

# the generated configuration
replace_regex /=.*setup_folder.*/=DIRECTORY_FILE_OR_FOLDER/
              /mysql_user=mariadb_restd_.*/mysql_user=mariadb_restd_RANDOM/
              /rest_daemon_id=.*/rest_daemon_id=UUID/
              /plugin_folder=.*/plugin_folder=ROUTER_PLUGIN_DIRECTORY/
              /destinations=.*/destinations=ADDR:PORT/ ;
--cat_file $MYSQL_TMP_DIR/setup_folder/mariadb-restd.conf

# the files of the deployment
--file_exists $MYSQL_TMP_DIR/setup_folder/mariadb-restd.key
--file_exists $MYSQL_TMP_DIR/setup_folder/data/keyring
--file_exists $MYSQL_TMP_DIR/setup_folder/data/router-cert.pem
--file_exists $MYSQL_TMP_DIR/setup_folder/data/router-key.pem
--file_exists $MYSQL_TMP_DIR/setup_folder/log
--file_exists $MYSQL_TMP_DIR/setup_folder/run

# the instance registered in the metadata
if ($setup_name_cmd) {
  --replace_regex /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/UUID/
  select id, name, product_name, options from mariadb_rest_service.rest_daemon;
}
if (!$setup_name_cmd) {
  --replace_regex /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/UUID/
  select id, product_name, options from mariadb_rest_service.rest_daemon;

  --replace_regex /^.+:8443$/"Name found"/
  select name from mariadb_rest_service.rest_daemon;
}

--replace_regex /"mariadb_restd_.*"/"mariadb_restd_RANDOM"/
select attributes from mariadb_rest_service.rest_daemon;

# the generated account and its roles
--replace_regex /mariadb_restd_[a-z0-9]+/mariadb_restd_RANDOM/
select user AS user, host AS host from mysql.user where user like 'mariadb_restd_%';
--replace_regex /mariadb_restd_[a-z0-9]+/mariadb_restd_RANDOM/
SELECT Role AS from_user, User AS to_user FROM mysql.roles_mapping WHERE User LIKE 'mariadb_restd_%' ORDER BY Role;

# Cleanup
--disable_query_log
--disable_result_log
--let $u1=`SELECT user from mysql.user WHERE user like "mariadb_restd_%";`
eval DROP USER $u1@'%';
--enable_query_log
--enable_result_log

DROP USER 'mrs_setup_user'@'%';
--force-rmdir $MYSQL_TMP_DIR/setup_folder

--let $cleanup_arg_mrs_skip_service_disable=1
--source ../include/mrs/cleanup.inc
