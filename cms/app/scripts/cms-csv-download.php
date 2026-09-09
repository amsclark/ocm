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

$username = '%%[username]%%';
$password = '%%[password]%%';
$url = '%%[url]%%';
$save_folder_path = '%%[save_folder_path]%%';

$c = curl_init();
curl_setopt($c, CURLOPT_URL, $url . '/services/table_listing.php');
echo "Connecting to {$url}\n";
curl_setopt($c, CURLOPT_TIMEOUT, 60);
curl_setopt($c, CURLOPT_RETURNTRANSFER, 1);
curl_setopt($c, CURLOPT_HTTPAUTH, CURLAUTH_ANY);
curl_setopt($c, CURLOPT_USERPWD, "$username:$password");
curl_setopt($c, CURLOPT_SSL_VERIFYPEER, FALSE);
curl_setopt($c, CURLOPT_SSL_VERIFYHOST, 2);
$status_code = curl_getinfo($c, CURLINFO_HTTP_CODE);
$result=curl_exec($c);
curl_close ($c);
$result = json_decode($result);

foreach ($result as $v)
{
	echo "Table {$v} ";
	$c = curl_init();
	curl_setopt($c, CURLOPT_URL, $url . '/services/csv.php?action=' . $v);
	curl_setopt($c, CURLOPT_TIMEOUT, 60);
	curl_setopt($c, CURLOPT_RETURNTRANSFER, 1);
	curl_setopt($c, CURLOPT_HTTPAUTH, CURLAUTH_ANY);
	curl_setopt($c, CURLOPT_USERPWD, "$username:$password");
	curl_setopt($c, CURLOPT_SSL_VERIFYPEER, FALSE);
	curl_setopt($c, CURLOPT_SSL_VERIFYHOST, 2);
	$status_code = curl_getinfo($c, CURLINFO_HTTP_CODE);
	$result=curl_exec($c);
	curl_close ($c);
	$file_path = $save_folder_path . '/' . $v . '.csv';
	file_put_contents($file_path, $result);
	echo "saved to {$file_path}\n";
}

?>