# mariadb-mrsd --setup against the test server
#
# $setup_name_cmd: optional, e.g. --name MyName

--source ../include/mrs/initialize_schema.inc

# an account with only the privileges --setup needs
CREATE USER mrs_setup_user IDENTIFIED BY 'pass';
GRANT SELECT, INSERT, UPDATE on mysql_rest_service_metadata.* to mrs_setup_user;
GRANT mysql_rest_service_data_provider TO mrs_setup_user WITH ADMIN OPTION;
GRANT CREATE USER ON *.* TO mrs_setup_user WITH GRANT OPTION;
GRANT mysql_rest_service_meta_provider TO mrs_setup_user WITH ADMIN OPTION;

--source setup_mrs_replace.inc
exec $MYSQLROUTER --setup mrs_setup_user:pass@127.0.0.1:$MASTER_MYPORT
   -d $MYSQL_TMP_DIR/setup_folder
   $setup_name_cmd
   --conf-set-option=DEFAULT.plugin_folder=$ROUTER_PLUGIN_DIRECTORY
   --jwt-secret something_important;

# the generated configuration
replace_regex /=.*setup_folder.*/=DIRECTORY_FILE_OR_FOLDER/
              /mysql_user=mariadb_mrsd1_.*/mysql_user=mariadb_mrsd1_RANDOM/
              /plugin_folder=.*/plugin_folder=ROUTER_PLUGIN_DIRECTORY/
              /destinations=.*/destinations=ADDR:PORT/ ;
--cat_file $MYSQL_TMP_DIR/setup_folder/mariadb-mrsd.conf

# the files of the deployment
--file_exists $MYSQL_TMP_DIR/setup_folder/mariadb-mrsd.key
--file_exists $MYSQL_TMP_DIR/setup_folder/data/keyring
--file_exists $MYSQL_TMP_DIR/setup_folder/data/router-cert.pem
--file_exists $MYSQL_TMP_DIR/setup_folder/data/router-key.pem
--file_exists $MYSQL_TMP_DIR/setup_folder/log
--file_exists $MYSQL_TMP_DIR/setup_folder/run

# the instance registered in the metadata
if ($setup_name_cmd) {
  select id, router_name, product_name, options from mysql_rest_service_metadata.router;
}
if (!$setup_name_cmd) {
  select id, product_name, options from mysql_rest_service_metadata.router;

  --replace_regex /^.+:8443$/"Name found"/
  select router_name from mysql_rest_service_metadata.router;
}

--replace_regex /"mariadb_mrsd1_.*"/"mariadb_mrsd1_RANDOM"/
select attributes from mysql_rest_service_metadata.router;

# the generated account and its roles
--replace_regex /mariadb_mrsd1_[a-z0-9]+/mariadb_mrsd1_RANDOM/
select user, host from mysql.user where user like 'mariadb_mrsd1_%';
--replace_regex /mariadb_mrsd1_[a-z0-9]+/mariadb_mrsd1_RANDOM/
select from_user, to_user from mysql.role_edges where to_user like 'mariadb_mrsd1_%' order by from_user;

# Cleanup
--disable_query_log
--disable_result_log
--let $u1=`SELECT user from mysql.user WHERE user like "mariadb_mrsd1_%";`
eval DROP USER $u1@'%';
--enable_query_log
--enable_result_log

DROP USER 'mrs_setup_user'@'%';
--force-rmdir $MYSQL_TMP_DIR/setup_folder

--let $cleanup_arg_mrs_skip_service_disable=1
--source ../include/mrs/cleanup.inc
