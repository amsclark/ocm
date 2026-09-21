<?php

/**********************************/
/* Pika CMS (C) 2008 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

/*	A session is required here. This endpoint ran with
	PL_DISABLE_SECURITY, which tells pika_init() to skip authenticate()
	altogether, so anyone who could reach the server could reach it --
	no account, no cookie. Nothing it serves is meant to be public.
	
	PL_DISABLE_DISPLAY_LOGIN is what makes that safe to fix without
	breaking the caller: pika_init() authenticates as it does on every
	other page, and a request with no session ends with an empty body
	rather than a login page rendered where a reply was expected. The
	same pair is used by cms/documents.php.
*/
define('PL_DISABLE_DISPLAY_LOGIN',true);

chdir('..');
require_once('pika-danio.php');
pika_init();



$zip = pl_grab_get('zip');
$zip = substr($zip, 0, 5);
$safe_zip = DB::escapeString($zip);

$buffer = '';
$city = '';
$state = '';
$county = '';
$doc = new DOMDocument();
$zipcode = $doc->createElement('zipcode');
$zipcode = $doc->appendChild($zipcode);

if (strlen($zip) == 5)
{
	$result = DB::query("SELECT city, state, county, zip FROM zip_codes WHERE zip='{$safe_zip}' LIMIT 1");
	$row = DBResult::fetchRow($result);
	$city = $row['city'];
	$state = $row['state'];
	$county = $row['county'];
	
	foreach ($row as $key => $val) {
		$node = $doc->createElement($key,$val);
		$zipcode->appendChild($node);
	}
	
}


$buffer = $doc->saveXML();
header('Content-type: text/xml');
exit($buffer);
?>
