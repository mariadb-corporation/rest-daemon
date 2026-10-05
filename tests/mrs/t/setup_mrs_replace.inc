# normalizes the output of mariadb-mrsd --setup for the next exec:
# deployment directory, program path, script name, server port and the
# default instance name (<hostname>:8443); \x27 is a single quote
replace_regex /[^ \x27]*setup_folder/DIRECTORY/
              /DIRECTORY[\\]/DIRECTORY\//
              /[^ \x27]*runtime_output_directory[\\\/]//
              /mariadb-mrsd\.exe/mariadb-mrsd/
              /start\.(sh|ps1)/START_SCRIPT/
              /127\.0\.0\.1:[0-9]+/127.0.0.1:PORT/
              /(\x27)[^\x27 ]+:8443\x27/\1HOSTNAME:8443\1/ ;
