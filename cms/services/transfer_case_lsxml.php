<?php

/***************************/
/* Pika CMS (C) 2015       */
/* Pika Software, LLC.     */
/* http://pikasoftware.com */
/***************************/

chdir('../');

define('PL_HTTP_SECURITY',true);

require_once ('pika-danio.php');
pika_init();
/*
require_once('pikaCase.php');
require_once('pikaContact.php');
require_once('pikaActivity.php');
*/
require_once('pikaLSXML_V2.php');

$auth_row = pikaAuthHttp::getInstance()->getAuthRow();
/*	Read this one straight out of $_POST. pl_grab_post() runs every value
	through pl_clean_form_input(), which rewrites < and > as &lt; and &gt;,
	and that turns an XML document into a string of escaped text that no
	parser can read. The document is validated where it is parsed instead:
	pikaLSXML's constructor refuses a DOCTYPE declaration and parses with
	LIBXML_NONET.
*/
$lsxml = isset($_POST['lsxml']) ? (string) $_POST['lsxml'] : '';

/*	A document this parser refuses is answered with a 400 and a one-line
	reason, not with an uncaught exception. An uncaught exception in this
	codebase reaches the caller as an empty 500 that says nothing, and the
	reason it was refused goes only into the web server log where the sending
	organisation cannot see it.
*/
try
{
	$tx = new pikaLSXML($lsxml);
	$case_id = $tx->importXML();
}
catch (Exception $e)
{
	pl_audit('lsxml_transfer.rejected','lsxml_transfer',null,array(
		'reason' => $e->getMessage(),
		'peer_user' => isset($auth_row['username']) ? (string) $auth_row['username'] : null,
		'remote_ip' => isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : null
		));
	header('HTTP/1.1 400 Bad Request');
	header('Content-Type: text/plain; charset=utf-8');
	echo "LSXML transfer rejected.\n";
	exit();
}
$case = new pikaCase($case_id);
$case->intake_user_id = $auth_row['user_id'];
$case->save();

/*	The reply is the new case id and nothing else. It used to be
	print_r($case), which dumps every column of the row back to the caller,
	including the ones the sending organisation never sent and has no
	business reading. The sender needs the id to reference the case later;
	it does not need our copy of it.
	
	The id is escaped even though it comes from the database, because it is
	the one value here the caller can influence and this reply is read by
	other software.
*/
header('Content-Type: text/plain; charset=utf-8');
echo '[' . htmlspecialchars((string) $case_id,ENT_QUOTES,'UTF-8') . ']';

exit();
