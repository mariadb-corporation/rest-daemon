# ==== Purpose ====

# get details from mariadb_rest_service.rest_daemon_status table

# Wait for the latest counter values.

--let $_mrs_definition_start=`SELECT NOW()`
--let $wait_condition=SELECT status_time>"$_mrs_definition_start" FROM mariadb_rest_service.rest_daemon_status WHERE rest_daemon_id='$extra_mrs_router_id' ORDER BY id DESC LIMIT 1;
--source include/wait_condition_or_abort.inc


--let $_status_wait_last_id=`SELECT id FROM mariadb_rest_service.rest_daemon_status ORDER BY id DESC LIMIT 1`

if (!$_status_wait_last_id)
{
  --die Something went wrong
}

--let $_mrs_definition_start=

