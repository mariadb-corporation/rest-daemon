# ==== Purpose ====

# get details from mariadb_rest_service.rest_daemon_status table

# Wait for the latest counter values.
--let $_mrs_definition_start=`SELECT NOW()`
--let $wait_condition=SELECT status_time>"$_mrs_definition_start" FROM mariadb_rest_service.rest_daemon_status WHERE rest_daemon_id='$extra_mrs_router_id' ORDER BY id DESC LIMIT 1;
--source include/wait_condition_or_abort.inc

if (!$_status_wait_last_id)
{
  --die Please first include mysqlrouter_reset_status.inc
}

--disable_query_log

# MAX is need for restCachedEndpoints, restCachedItems, restCachedFiles, those are not resetable counters.
# for others SUM.
eval select json_object(
        'endpoints', MAX(JSON_EXTRACT(details,'$.restCachedEndpoints')),
        'items', MAX(JSON_EXTRACT(details,'$.restCachedItems')),
        'files', MAX(JSON_EXTRACT(details,'$.restCachedFiles')),
        'itemLoads', SUM(JSON_EXTRACT(details,'$.restCacheItemLoads')),
        'itemEjects', SUM(JSON_EXTRACT(details,'$.restCacheItemEjects')),
        'itemHits', SUM(JSON_EXTRACT(details,'$.restCacheItemHits')),
        'itemMisses', SUM(JSON_EXTRACT(details,'$.restCacheItemMisses')),
        'fileLoads', SUM(JSON_EXTRACT(details,'$.restCacheFileLoads')),
        'fileEjects', SUM(JSON_EXTRACT(details,'$.restCacheFileEjects')),
        'fileHits', SUM(JSON_EXTRACT(details,'$.restCacheFileHits')),
        'fileMisses', SUM(JSON_EXTRACT(details,'$.restCacheFileMisses'))
        ) as stats from mariadb_rest_service.rest_daemon_status WHERE  id > $_status_wait_last_id;
--enable_query_log

--let $_mrs_definition_start=
--let $_status_wait_last_id=
