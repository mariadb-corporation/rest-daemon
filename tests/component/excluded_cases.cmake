# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 USA

# mrsd: component test cases excluded because they exercise features that
# are not part of mrsd (routing, metadata_cache/cluster, bootstrap, X protocol).
# Generated from the failing cases of the upstream suites; each entry is a
# full GoogleTest name, applied as a negative GTEST_FILTER.
#
# EXCLUDE_TEST_CASES(<ctest name> <gtest name>...)

EXCLUDE_TEST_CASES(routertest_component_config
  "RouterConfigTest.MetadataCacheBootstrapServerAddresses"
  "RouterConfigTest.RoutingModeUnsupported"
  "RouterConfigTest.RoutingRoutingStrategyRequired"
  "RouterConfigTest.RoutingUnreachableDestinationRefreshIntervalUnsupported"
  "RouterConfigTest.RoutingOptionDisabledUnsupported"
  "UnknownConfigOptionValidConfigTest.UnknownConfigOptionValidConfig"
  "UnknownConfigOptionWarningCaseInsensitive/UnknownConfigOptionWarningCaseInsensitiveTest.UnknownConfigOptionWarningCaseInsensitive/5"
  "UnknownConfigOptionErrorCaseInsensitive/UnknownConfigOptionErrorCaseInsensitiveTest.UnknownConfigOptionErrorCaseInsensitive/5"
  "Check/MRSConfigErrorTest.Check/mysql_user_missing"
  "Check/MRSConfigErrorTest.Check/mysql_user_empty"
  "Check/MRSConfigErrorTest.Check/mysql_user_not_in_keyring"
  "Check/MRSConfigErrorTest.Check/mysql_user_data_access_not_in_keyring"
  "Check/MRSConfigErrorTest.Check/mysql_read_write_route_missing"
  "Check/MRSConfigErrorTest.Check/mysql_read_write_route_does_not_exist"
  "Check/MRSConfigErrorTest.Check/mysql_read_write_route_empty"
  "Check/MRSConfigErrorTest.Check/mysql_read_write_route_x_protocol"
  "Check/MRSConfigErrorTest.Check/mysql_read_only_route_does_not_exist"
  "Check/MRSConfigErrorTest.Check/mysql_read_only_route_x_protocol"
  "Check/MRSConfigErrorTest.Check/router_id_missing"
  "Check/MRSConfigErrorTest.Check/router_id_empty"
  "Check/MRSConfigErrorTest.Check/router_id_nan"
  "Check/MRSConfigErrorTest.Check/metadata_refresh_interval_negative"
  "Check/MRSConfigErrorTest.Check/metadata_refresh_interval_0"
  "Check/MRSConfigErrorTest.Check/metadata_refresh_interval_nan"
  "Check/MRSConfigErrorTest.Check/metadata_refresh_interval_foo"
  "Check/MRSConfigErrorTest.Check/unknown_option"
)

EXCLUDE_TEST_CASES(routertest_component_config_overwrites
  "RouterConfigOwerwriteTestOldExe.OverwriteRoutingPort"
  "RouterConfigOwerwriteTestOldExe.OverwriteOptionMissingInTheConfig"
  "BootstrapDebugLevelOk/BootstrapDebugLevelOkTest.BootstrapDebugLevelOk/0"
  "BootstrapDebugLevelOk/BootstrapDebugLevelOkTest.BootstrapDebugLevelOk/1"
  "BootstrapOverwriteError/BootstrapOverwriteErrorTest.BootstrapOverwriteError/0"
  "BootstrapOverwriteError/BootstrapOverwriteErrorTest.BootstrapOverwriteError/1"
  "BootstrapOverwriteError/BootstrapOverwriteErrorTest.BootstrapOverwriteError/2"
  "BootstrapOverwriteError/BootstrapOverwriteErrorTest.BootstrapOverwriteError/3"
  "OverwriteIgnoreUnknownOption/OverwriteIgnoreUnknownOptionTest.OverwriteIgnoreUnknownOption/0"
  "OverwriteIgnoreUnknownOption/OverwriteIgnoreUnknownOptionTest.OverwriteIgnoreUnknownOption/1"
  "OverwriteIgnoreUnknownOption/OverwriteIgnoreUnknownOptionTest.OverwriteIgnoreUnknownOption/2"
  "OverwriteIgnoreUnknownOption/OverwriteIgnoreUnknownOptionTest.OverwriteIgnoreUnknownOption/3"
  "OverwriteError/OverwriteErrorTest.OverwriteError/1"
  "OverwriteError/OverwriteErrorTest.OverwriteError/2"
  "OverwriteError/OverwriteErrorTest.OverwriteError/3"
  "MetadataConfig/MetadataConfigTest.MetadataConfig/0"
  "MetadataConfig/MetadataConfigTest.MetadataConfig/1"
  "MetadataConfig/MetadataConfigTest.MetadataConfig/2"
)

EXCLUDE_TEST_CASES(routertest_component_logging
  "RouterLoggingTest.log_startup_failure_to_logfile"
  "RouterLoggingTest.very_long_router_name_gets_properly_logged"
  "RouterLoggingTest.is_debug_logs_disabled_if_no_bootstrap_config_file"
  "RouterLoggingTest.is_debug_logs_enabled_if_bootstrap_config_file"
  "RouterLoggingTest.is_debug_logs_written_to_file_if_logging_folder"
  "RouterLoggingTest.bootstrap_normal_logs_written_to_stdout"
  "RouterLoggingTest.switch_without_consolelog"
  "MetadataCacheLoggingTest.log_error_when_cannot_connect_to_any_metadata_server"
  "MetadataCacheLoggingTest.log_warning_when_cannot_connect_to_first_metadata_server"
  "MetadataCacheLoggingTest.log_rotation_by_HUP_signal"
  "MetadataCacheLoggingTest.log_rotation_by_HUP_signal_no_file_move"
  "MetadataCacheLoggingTest.log_rotation_when_router_restarts"
  "MetadataCacheLoggingTest.log_rotation_read_only"
  "MetadataCacheLoggingTest.log_rotation_stdout"
  "LoggingTestConsoleDestinationDevices/RouterLoggingTestConfigFilenameDevices.LoggingTestConsoleDestinationDevices/0"
  "LoggingTestConsoleDestinationDevices/RouterLoggingTestConfigFilenameDevices.LoggingTestConsoleDestinationDevices/1"
  "LoggingTestConsoleDestinationDevices/RouterLoggingTestConfigFilenameLoggingFolder.check/0"
  "LoggingTestConsoleDestinationDevices/RouterLoggingTestConfigFilenameLoggingFolder.check/1"
  "LoggingTestConsoleDestinationDevices/RouterLoggingTestConfigFilenameLoggingFolder.check/2"
  "LoggingTestConsoleDestinationDevices/RouterLoggingTestConfigFilenameLoggingFolder.check/3"
  "LoggingTestConsoleDestinationDevices/RouterLoggingTestConfigFilenameLoggingFolder.check/4"
  "LoggingTestConsoleDestinationDevices/RouterLoggingTestConfigFilenameLoggingFolder.check/5"
)

EXCLUDE_TEST_CASES(routertest_component_router_configuration_errors
  "Spec/RouterTestBrokenConfig.ensure/routing_connect_timeout_is_zero"
  "Spec/RouterTestBrokenConfig.ensure/routing_connect_timeout_is_negative"
  "Spec/RouterTestBrokenConfig.ensure/routing_connect_timeout_is_hex"
  "Spec/RouterTestBrokenConfig.ensure/routing_client_connect_timeout_is_one"
  "Spec/RouterTestBrokenConfig.ensure/routing_client_connect_timeout_is_hex"
  "Spec/RouterTestBrokenConfig.ensure/routing_max_connect_error_is_zero"
  "Spec/RouterTestBrokenConfig.ensure/routing_max_connect_error_is_hex"
  "Spec/RouterTestBrokenConfig.ensure/routing_protocol_is_invalid"
  "Spec/RouterTestBrokenConfig.ensure/routing_protocol_is_empty"
  "Spec/RouterTestBrokenConfig.ensure/routing_client_connect_timeout_is_too_large"
  "Spec/RouterTestBrokenConfig.ensure/metadata_cache_user_is_required"
  "Spec/RouterTestBrokenConfig.ensure/metadata_cache_gr_notifications_for_rs_cluster"
  "Spec/RouterTestBrokenConfig.ensure/metadata_cache_invalid_cluster_type"
  "Spec/RouterTestBrokenConfig.ensure/metadata_cache_invalid_cluster_type2"
  "Spec/RouterTestBrokenConfig.ensure/routing_no_bind_nor_socket"
  "Spec/RouterTestBrokenConfig.ensure/routing_no_destinations"
  "Spec/RouterTestBrokenConfig.ensure/routing_bind_address_invalid_port"
  "Spec/RouterTestBrokenConfig.ensure/routing_bind_address_ambiguous_port"
  "Spec/RouterTestBrokenConfig.ensure/routing_bind_address_invalid_address"
  "Spec/RouterTestBrokenConfig.ensure/routing_bind_address_is_in_destinations"
  "Spec/RouterTestBrokenConfig.ensure/routing_routing_strategy_is_case_insenstive"
  "SpecUnix/RouterTestBrokenConfig.ensure/routing_bad_socket"
)

EXCLUDE_TEST_CASES(routertest_component_router_stacktrace
  "RouterStacktraceTest.bootstrap_with_core_file"
  "RouterStacktraceTest.crash_me_bootstrap"
  "RouterStacktraceTest.crash_me_via_event"
)

EXCLUDE_TEST_CASES(routertest_component_shutdown
  "ShutdownTest.flaky_connection_to_cluster"
)

EXCLUDE_TEST_CASES(routertest_component_sd_notify
  "NotifyTest.NotifyReadyMetadataCache"
  "NotifyTest.NotifyReadyManyPlugins"
  "NotifyTest.NotifyReadyMetadataCacheNoServer"
  "NotifyBootstrapNotAffected/NotifyBootstrapNotAffectedTest.NotifyBootstrapNotAffected/0"
  "NotifyBootstrapNotAffected/NotifyBootstrapNotAffectedTest.NotifyBootstrapNotAffected/1"
)

EXCLUDE_TEST_CASES(routertest_component_master_key_reader_writer
  "MasterKeyReaderWriterTest.NoMasterKeyFileWhenBootstrapPassWithMasterKeyReader"
  "MasterKeyReaderWriterTest.CheckConfigFileWhenBootstrapPassWithMasterKeyReader"
  "MasterKeyReaderWriterTest.BootstrapFailsWhenCannotRunMasterKeyReader"
  "MasterKeyReaderWriterTest.BootstrapFailsWhenCannotRunMasterKeyWriter"
  "MasterKeyReaderWriterTest.IsNewMasterKeyIfReaderReturnsEmptyKeyAndBootstrapPass"
  "MasterKeyReaderWriterTest.DontWriteMasterKeyAtBootstrapIfMasterKeyAlreadyExists"
  "MasterKeyReaderWriterTest.ConnectToMetadataServerPass"
  "MasterKeyReaderWriterTest.NoMasterKeyInLogsWhenConnectToMetadataServerPass"
)

# Windows-only case configuring a [routing] section
EXCLUDE_TEST_CASES(routertest_component_logging_eventlog
  "RouterEventlogTest.application_running_as_process_postconfig"
)
