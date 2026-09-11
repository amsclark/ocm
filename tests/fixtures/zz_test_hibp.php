<?php
/*	A stand-in for the Pwned Passwords range endpoint, for smoke.sh.
	
	The real service is a third party on the public internet. A test that
	called it would need a route out of the CI network, would tell that
	third party what the test is doing, and would fail for reasons that have
	nothing to do with this application. This serves the same shape of
	answer from inside the container instead.
	
	Requested as <this file>/<5 hex characters>, the way the real endpoint is
	requested, and answered with one "<35 hex characters>:<count>" line per
	hash it holds that begins with those characters.
	
	State lives in /tmp/zz_test_hibp:
	
		passwords   one password per line. Any password listed here is
		            reported as breached; anything else is reported clean.
		flags       'fail' to answer 500, so a test can see what the
		            application does when the service is unreachable.
	
	Installed into the web root by smoke.sh and deleted again afterwards.
	It refuses to do anything unless its state directory exists, so a copy
	left behind by a killed run is inert.
*/

$STATE_DIR = '/tmp/zz_test_hibp';

if (!is_dir($STATE_DIR))
{
	header('HTTP/1.1 404 Not Found');
	exit;
}

$flags = file_exists($STATE_DIR . '/flags')
	? trim(file_get_contents($STATE_DIR . '/flags'))
	: '';

if ('fail' === $flags)
{
	header('HTTP/1.1 500 Internal Server Error');
	echo "the service is having a bad day\n";
	exit;
}

/*	PATH_INFO where the server provides it, and the tail of the request
	otherwise -- not every configuration fills PATH_INFO in.
*/
$tail = isset($_SERVER['PATH_INFO']) ? (string) $_SERVER['PATH_INFO'] : '';

if ('' === $tail && isset($_SERVER['REQUEST_URI']))
{
	$path = (string) parse_url((string) $_SERVER['REQUEST_URI'], PHP_URL_PATH);
	$at   = strpos($path, basename(__FILE__));
	
	if (false !== $at)
	{
		$tail = substr($path, $at + strlen(basename(__FILE__)));
	}
}

$prefix = strtoupper(trim($tail, '/'));

if (!preg_match('/^[0-9A-F]{5}$/', $prefix))
{
	header('HTTP/1.1 400 Bad Request');
	exit;
}

$passwords = file_exists($STATE_DIR . '/passwords')
	? preg_split('/\r?\n/', (string) file_get_contents($STATE_DIR . '/passwords'))
	: array();

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

/*	A decoy on every answer. The real endpoint never returns an empty body
	for a valid prefix, and an application that matched on "the body is not
	empty" rather than on the suffix would pass a weaker test without it.
*/
echo str_repeat('0', 35) . ":1\n";

foreach ($passwords as $password)
{
	$password = rtrim($password, "\r\n");
	
	if ('' === $password)
	{
		continue;
	}
	
	$hash = strtoupper(sha1($password));
	
	if (substr($hash, 0, 5) === $prefix)
	{
		echo substr($hash, 5) . ":424242\n";
	}
}
