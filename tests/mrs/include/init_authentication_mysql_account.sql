# Do not reuse this file.
#
# Any router test that uses a non-root account in the router configuration
# must duplicate this file to ensure the server is restarted between tests.
#
# Note: The test that includes this file is responsible for clearing the data.
#
CREATE ROLE IF NOT EXISTS 'mariadb_rest_service_meta_provider', 'mariadb_rest_service_data_provider';
CREATE USER IF NOT EXISTS 'mrs_user'@'%' IDENTIFIED WITH caching_sha2_password BY '';
GRANT mariadb_rest_service_meta_provider TO mrs_user WITH ADMIN OPTION;
GRANT mariadb_rest_service_data_provider TO mrs_user WITH ADMIN OPTION;
