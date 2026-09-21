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



$problem = pl_grab_get('problem');
$problem = substr($problem, 0, 2);
$safe_problem = DB::escapeString($problem);

$buffer = '';

$doc = new DOMDocument();
$problem_xml = $doc->createElement('problem_codes');
$problem_xml = $doc->appendChild($problem_xml);

if (strlen($problem) == 2)
{
	$sql = "SELECT value, label FROM menu_sp_problem WHERE value LIKE '{$safe_problem}%' ORDER BY menu_order";
	$result = DB::query($sql);
	while ($row = DBResult::fetchRow($result)) {
		$problem_node = $doc->createElement('problem');
		$problem_node = $problem_xml->appendChild($problem_node);
			$node = $doc->createElement('value', pl_clean_html($row['value']));
			$node = $problem_node->appendChild($node);
			$node = $doc->createElement('label', pl_clean_html($row['label']));
			$node = $problem_node->appendChild($node);
			
	}
	
}


$buffer = $doc->saveXML();
header('Content-type: text/xml');
exit($buffer);
?>
