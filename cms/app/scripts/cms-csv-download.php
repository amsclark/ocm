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

/*	The export list is this installation's own tables, as they were when the
	script was downloaded, less doc_storage. system-mac_download.php writes it
	in. Download the script again after adding a table.
*/
$allowed_tables = explode(',', '%%[allowed_tables]%%');

$save_folder_path = realpath($save_folder_path);
if ($save_folder_path === FALSE || !is_dir($save_folder_path))
{
	fwrite(STDERR, "The save folder does not exist.\n");
	exit(1);
}
$save_folder_prefix = rtrim($save_folder_path, DIRECTORY_SEPARATOR) .
	DIRECTORY_SEPARATOR;

$c = curl_init();
curl_setopt($c, CURLOPT_URL, $url . '/services/table_listing.php');
fwrite(STDOUT, "Connecting to {$url}\n");
curl_setopt($c, CURLOPT_TIMEOUT, 60);
curl_setopt($c, CURLOPT_RETURNTRANSFER, 1);
curl_setopt($c, CURLOPT_HTTPAUTH, CURLAUTH_ANY);
curl_setopt($c, CURLOPT_USERPWD, "$username:$password");
/*	This request carries the operator's own OCM username and password as
	HTTP Basic credentials, over a URL the download page builds as https.
	Peer verification was off, so any host able to answer for that name --
	anything on the network path, or a DNS answer an attacker controls --
	could present a certificate of its own, and curl would hand it the
	password. Verifying the host name while not verifying the certificate
	that carries it checks nothing at all.
*/
curl_setopt($c, CURLOPT_SSL_VERIFYPEER, TRUE);
curl_setopt($c, CURLOPT_SSL_VERIFYHOST, 2);
$status_code = curl_getinfo($c, CURLINFO_HTTP_CODE);
$result=curl_exec($c);
curl_close ($c);
$result = json_decode($result);

/*	json_decode() returns null for a body that is not JSON at all, and the
	foreach below was reached either way: on PHP 8 that is a warning on every
	failed run and no other sign that the download did nothing.
*/
if (!is_array($result))
{
	die("The server did not return a list of tables.\n");
}

foreach ($result as $v)
{
	/*	Remote names must select an entry from the fixed export list. Only
		the selected local value reaches the URL, output, or file path.
	*/
	if (!is_string($v) || !preg_match('/^[A-Za-z0-9_]+\z/', (string) $v))
	{
		fwrite(STDOUT, "Skipped a table name that is not a plain identifier.\n");
		continue;
	}
	$table_index = array_search($v, $allowed_tables, TRUE);
	if ($table_index === FALSE)
	{
		fwrite(STDOUT, "Skipped a table name outside the export list.\n");
		continue;
	}
	$table = $allowed_tables[$table_index];
	$file_path = $save_folder_prefix . $table . '.csv';

	/*	An existing link could redirect an otherwise safe file name outside
		the save folder. Reject links, including links to missing targets.
	*/
	if (is_link($file_path) ||
		strncmp($file_path, $save_folder_prefix, strlen($save_folder_prefix)) !== 0 ||
		dirname($file_path) !== $save_folder_path)
	{
		fwrite(STDERR, "Skipped an unsafe export file path.\n");
		continue;
	}
	if (file_exists($file_path))
	{
		$existing_path = realpath($file_path);
		if ($existing_path === FALSE || !is_file($existing_path) ||
			dirname($existing_path) !== $save_folder_path)
		{
			fwrite(STDERR, "Skipped an unsafe export file path.\n");
			continue;
		}
	}

	fwrite(STDOUT, "Table {$table} ");
	$c = curl_init();
	curl_setopt($c, CURLOPT_URL, $url . '/services/csv.php?action=' . $table);
	curl_setopt($c, CURLOPT_TIMEOUT, 60);
	curl_setopt($c, CURLOPT_RETURNTRANSFER, 1);
	curl_setopt($c, CURLOPT_HTTPAUTH, CURLAUTH_ANY);
	curl_setopt($c, CURLOPT_USERPWD, "$username:$password");
	// Same credentials, same reason as the request above.
	curl_setopt($c, CURLOPT_SSL_VERIFYPEER, TRUE);
	curl_setopt($c, CURLOPT_SSL_VERIFYHOST, 2);
	$status_code = curl_getinfo($c, CURLINFO_HTTP_CODE);
	$result=curl_exec($c);
	curl_close ($c);
	if (file_put_contents($file_path, $result) === FALSE)
	{
		fwrite(STDERR, "Could not save the exported table.\n");
		continue;
	}
	fwrite(STDOUT, "saved to {$file_path}\n");
}

?>
