# ==== Purpose ====
#
# Shut down mysqlrouter.
#
# ==== Usage ====
#
# --let $pid_file = /path/to/the/file.pid
# --source shutdown_mysqlrouter.inc
#
if (!$pid_file)
{
  die "The shutdown script, requires that PID file is specified.";
}
--let MYSQLROUTER_PIDFILE = $pid_file

# mrsd: stop the router through the pytest harness (upstream: a perl block
# killing the PID from $MYSQLROUTER_PIDFILE; Win32::Process isn't available
# everywhere)
--mrsd_stop
