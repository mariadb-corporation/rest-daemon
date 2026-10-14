# Make sure the MRS loaded the metadata after it was (re-)created.

--let $_mrs_definition_start=`SELECT NOW()`
--let $wait_condition=SELECT last_check_in>"$_mrs_definition_start" FROM mariadb_rest_service.rest_daemon WHERE id='$extra_mrs_router_id';
--source include/wait_condition_or_abort.inc

--let $_mrs_definition_start=
