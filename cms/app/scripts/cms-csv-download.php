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
	/*	$v is a table name read out of the answer the far end sent, and the
		path below puts a separator in front of it. A server answering this
		request could therefore name a table '../../../../etc/cron.d/x' and
		have this script -- which runs from the operator's cron, as the
		operator -- write a file of the server's choosing anywhere that user
		can write. Hold the name to the shape a table name has.
	*/
	if (!preg_match('/^[A-Za-z0-9_]+\z/', (string) $v))
	{
		echo "Skipped a table name that is not a plain identifier.\n";
		continue;
	}
	
	echo "Table {$v} ";
	$c = curl_init();
	curl_setopt($c, CURLOPT_URL, $url . '/services/csv.php?action=' . $v);
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
	$file_path = $save_folder_path . '/' . $v . '.csv';
	file_put_contents($file_path, $result);
	echo "saved to {$file_path}\n";
}

?>