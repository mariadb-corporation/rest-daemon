# Wait until the service /svc lists the auth app $wait_for_app (30 s).
#
# --let $wait_for_app=<name>
# --source ../include/test/wait_for_auth_app.inc

# (an environment name with no case-insensitive twin among the variables:
# on Windows WAIT_FOR_APP and $wait_for_app would be the same name)
--let MRS_LISTED_APP=$wait_for_app
--perl
my $app = $ENV{MRS_LISTED_APP} or die "MRS_LISTED_APP is not set\n";
my $cmd = "$ENV{MRS_CLIENT_ARGS} --path /svc/authentication/authApps --display body";
# Windows: the backticks run through Git's sh, which reads backslashes as
# escapes and would rewrite the /svc/... argument into a Windows path
$cmd =~ s{\\}{/}g;
$ENV{MSYS_NO_PATHCONV} = 1;
$ENV{MSYS2_ARG_CONV_EXCL} = '*';
for (1 .. 30) {
  my $out = `$cmd 2>&1`;
  if ($out =~ /"$app"/) { print "$app is listed\n"; exit 0; }
  sleep 1;
}
my $last = `$cmd 2>&1`;
die "$app is not listed after 30 s:\n$last\n";
EOF
