--let $_mrs_max_log_id=`select IFNULL(max(id), 0) from mariadb_rest_service.rest_daemon_general_log`
--let $wait_condition=SELECT id FROM mariadb_rest_service.rest_daemon_general_log WHERE rest_daemon_id='$extra_mrs_router_id' and id > $_mrs_max_log_id;
--source include/wait_condition_or_abort.inc

--let $_mrs_max_log_id=
