<?php

chdir('..');
require_once('pika-danio.php');

pika_init();

/*	Every POST to this handler must carry the per-session CSRF token.
	See pl_csrf_check() in cms/app/lib/pl.php for the framework.
	
	js/save_report.js sends the report parameters as a raw text/xml request
	body rather than as a form encoding, so PHP populates no $_POST at all
	and there is no _csrf field for pl_csrf_check() to read. The token
	arrives in an X-CSRF-Token header instead; copy it across before the
	check, which is the same shape the framework expects.
*/
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	$csrf_header = isset($_SERVER['HTTP_X_CSRF_TOKEN']) ? (string) $_SERVER['HTTP_X_CSRF_TOKEN'] : '';
	
	if (strlen($csrf_header) > 0 && !isset($_POST['_csrf']))
	{
		$_POST['_csrf'] = $csrf_header;
	}
	
	pl_csrf_check();
}

/*	js/save_report.js used to fire this request and reload the saved-report
	list without ever looking at the answer, so a refusal here was invisible:
	the list came back without the new entry and the person who had just spent
	ten minutes setting up a report was left to work out for themselves that
	nothing had been saved.
	
	The browser now waits for the answer, so this handler has to give one.
	Say OK on the single path that stores a document, and otherwise send a
	status the browser can act on with one line of plain text explaining it.
	The body is text/plain so nothing here can be mistaken for markup, and it
	ends the request the way die() did rather than through pika_exit(), which
	would run the reply through the page template.
*/
function pl_upload_report_reply($status, $message)
{
	if (!headers_sent())
	{
		http_response_code($status);
		header('Content-Type: text/plain; charset=UTF-8');
	}
	
	echo $message;
	exit();
}

/*	This handler stores a report definition, which is a document every
	user of the site then runs. It had no permission check, so any signed-in
	user could install one. Report definitions are administrator material.
*/
if (!pika_authorize('system',array()))
{
	pl_upload_report_reply(403, 'Access denied');
}

require_once('pikaDocument.php');
require_once('pikaMisc.php');

/*	Initialised before the branch. It was read by loadXML() below whether
	or not the POST branch had assigned it, which is an undefined-variable
	warning on PHP 8 for every non-POST request.
*/
$postText = '';

if ( $_SERVER['REQUEST_METHOD'] === 'POST' ){ 
        $postText = file_get_contents('php://input'); 
}
$report_name = pl_grab_get('report_name');
$doc_name = pl_grab_get('doc_name');
$report_list = pikaMisc::reportList();
$xml_doc = new DOMDocument();

if (!$report_name)
{
	pl_upload_report_reply(400, 'The report was not saved: the request did not say which report it belongs to.');
}

/*	LIBXML_NONET so the parser cannot be talked into fetching a DTD or an
	entity over the network by the document it is reading. Entity
	substitution is already off -- LIBXML_NOENT is not passed -- so this
	closes the remaining half of XXE rather than opening anything.
*/
if (!$postText || !@$xml_doc->loadXML($postText, LIBXML_NONET))
{
	pl_upload_report_reply(400, 'The report was not saved: the settings did not arrive in a readable form.');
}

//print_r($report_list);
$contents = $xml_doc->saveXML();
if(function_exists('mb_strlen')) {
	$doc_size = mb_strlen($contents);	
} else {
	$doc_size = strlen($contents);
}
$doc = new pikaDocument();
$doc->doc_data = addslashes(gzcompress($contents,9));
$report_file_name = $report_name . ' Saved ' . date('m/d/Y');
if($doc_name && strlen($doc_name))	{
	$report_file_name = $doc_name;
}


/*	A foreach over $result stood here. Nothing in this file ever
	assigned $result, so on PHP 8 it was a warning on every save and
	nothing else: the loop body could not run. Removed rather than
	guarded, because there is no value to guard.
*/
$doc->doc_name = $report_file_name;
$doc->report_name = $report_name;
$doc->description = $report_name . " saved " . date('m/d/Y');
$doc->mime_type = 'text/xml';
$doc->doc_type = 'R';
$doc->doc_size = $doc_size;
$doc->user_id = $auth_row['user_id'];
$doc->created = date('Y-m-d');
$doc->save();

pl_upload_report_reply(200, 'OK');
