<?php

// CLI only. This file does its work at top level with no authentication check
// because the only assumed caller is cron or an operator with a shell -- but it
// sits under the document root, and Apache would run it for anyone who asked
// for the path. docker/apache.conf now denies /cms/app/ outright; this guard is
// the second lock, so the script stays safe under a vhost that lacks that rule.
if (PHP_SAPI !== 'cli' && PHP_SAPI !== 'phpdbg')
{
	header('HTTP/1.1 403 Forbidden');
	header('Content-Type: text/plain; charset=utf-8');
	error_log('Refused HTTP invocation of CLI script: ' . basename(__FILE__));
	die("This script is command-line only.\n");
}

set_time_limit(0);
$db_host = 'localhost';
$db_name = '';
$db_user = '';
$db_password = '';

mysql_connect($db_host, $db_user, $db_password);
mysql_select_db($db_name);

$r = mysql_query('SELECT alias_id, last_name, first_name FROM aliases WHERE mp_first IS NULL AND mp_last IS NULL ORDER BY alias_id');

while ($a = mysql_fetch_assoc($r))
{
	$alias_id=$a['alias_id'];
	$first_arr = explode(" ", $a['first_name']);
	$mp_first=metaphone($first_arr[0]);
	$mp_last=metaphone($a['last_name']);
	echo "UPDATE LOW_PRIORITY aliases SET mp_first='$mp_first', mp_last='$mp_last' WHERE alias_id='$alias_id' AND mp_first IS NULL AND mp_last IS NULL LIMIT 1;\n";
}

$r = mysql_query('SELECT contact_id, last_name, first_name FROM contacts WHERE mp_first IS NULL AND mp_last IS NULL ORDER BY contact_id');

while ($a = mysql_fetch_assoc($r))
{
	$contact_id=$a['contact_id'];
	$first_arr = explode(" ", $a['first_name']);
	$mp_first=metaphone($first_arr[0]);
	$mp_last=metaphone($a['last_name']);
	echo "UPDATE LOW_PRIORITY contacts SET mp_first='$mp_first', mp_last='$mp_last' WHERE contact_id='$contact_id' AND mp_first IS NULL AND mp_last IS NULL LIMIT 1;\n";
}

exit();

?>
