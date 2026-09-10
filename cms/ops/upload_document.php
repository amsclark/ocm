<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

chdir('../');

require_once ('pika-danio.php');
pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

require_once('pikaDocument.php');

$file_array = array();
if (isset($_FILES['doc_upload'])) {
	$file_array = $_FILES['doc_upload'];
}
$description = pl_grab_post('description');
$case_id = pl_grab_post('case_id');
$doc_type = pl_grab_post('doc_type');
$folder = pl_grab_post('folder');
$folder_name = pl_grab_post('folder_name');
$report_name = pl_grab_post('report_name');
$parent_folder = pl_grab_post('parent_folder');
$base_url = pl_settings_get('base_url');

// -- Authorization ---------------------------------------------------
// This gate covers EVERY write the endpoint performs -- document upload
// and folder creation alike -- and it DENIES BY DEFAULT.
//
// There was no authorization check here at all. Any authenticated
// session, including one belonging to a group with no permissions
// whatsoever (read_all/edit_all/users/pba/motd/can_export all 0,
// read_office/edit_office/reports all NULL), could upload a document
// into any case, create system form-template folders, and store
// doc_storage rows under doc_type 'R', 'U', an unknown letter or an
// empty string.
//
// The permission per type reuses the predicates the rest of the
// document code already applies -- nothing new is invented here:
//
//   'C'  case document -> pika_authorize('edit_case') on THAT case, the
//        same predicate cms/documents.php applies to case documents.
//        Being logged in is not enough; the user must have write rights
//        on the specific case.
//
//   'F'  system form template -> pika_authorize('system').
//        system-forms.php is a System-menu surface and these templates
//        are org-wide.
//
//   'R'  saved report doc/folder -> pika_report_authorize($report_name),
//        the existing per-report gate keyed off groups.reports. That is
//        the same permission that decides whether the user may run the
//        report these documents hang off, so it is the right one for
//        writing into its saved-report folder.
//
//   'U'  user files -> refused. pikaDocument's doc_type map still lists
//        it, but nothing in the UI posts it to this endpoint, so there
//        is no permission to preserve and no reason to leave a writable
//        path open. Falls into the default-deny below.
//
// Anything else -- including an empty doc_type -- is refused, so the
// next doc_type someone adds cannot be silently ungated.
//
// Normalise first: pl_grab_post() hands back whatever the client sent,
// so an array doc_type would make every === comparison below false and
// land on default-deny anyway -- but only once it is a string can the
// audit line record it safely.
$doc_type = is_scalar($doc_type) ? (string) $doc_type : '';

$deny_upload = function ($reason) use ($doc_type)
{
	if (function_exists('pl_audit'))
	{
		pl_audit('document.upload.denied', 'doc_storage', null, array(
			'reason'   => $reason,
			'doc_type' => $doc_type,
		));
	}
	if (!headers_sent())
	{
		http_response_code(403);
		header('Content-Type: text/plain; charset=utf-8');
	}
	echo "Access denied.\n";
	exit();
};

if ($doc_type === 'C')
{
	// A case document must name a real case, otherwise there is nothing
	// to authorize against.
	if (!is_numeric($case_id) || (int) $case_id <= 0)
	{
		$deny_upload('missing_case_id');
	}
	// Confirm the row exists BEFORE constructing pikaCase. plBase's
	// constructor answers a missing row with trigger_error(), and
	// pl_error_handler() turns E_USER_NOTICE into the generic error page
	// and pika_exit()s -- so `new pikaCase($absent_id)` never returns and
	// a check made afterwards can never run. The caller would get a 200
	// error page instead of a refusal, and nothing would be audited.
	$case_exists = false;
	$result = DB::query(
		"SELECT case_id FROM cases WHERE case_id = '"
		. DB::escapeString((string) (int) $case_id) . "' LIMIT 1"
	);
	if ($result && DBResult::numRows($result) > 0)
	{
		$case_exists = true;
	}
	if (!$case_exists)
	{
		$deny_upload('unknown_case');
	}
	
	require_once('pikaCase.php');
	$case_check = new pikaCase((int) $case_id);
	// Read the row through getValues() rather than testing
	// empty($case_check->case_id): plBase exposes columns through
	// __get() but defines no __isset(), so empty()/isset() on a magic
	// property is ALWAYS true regardless of the loaded value and the
	// check would reject every case, valid or not.
	$case_values = $case_check->getValues();
	if (!is_array($case_values) || empty($case_values['case_id']))
	{
		$deny_upload('unknown_case');
	}
	if (!pika_authorize('edit_case', $case_values))
	{
		$deny_upload('edit_case');
	}
}
elseif ($doc_type === 'F')
{
	if (!pika_authorize('system', array()))
	{
		$deny_upload('system');
	}
}
elseif ($doc_type === 'R')
{
	if (!is_string($report_name) || trim($report_name) === '')
	{
		$deny_upload('missing_report_name');
	}
	if (!pika_report_authorize($report_name))
	{
		$deny_upload('report_authorize');
	}
}
else
{
	$deny_upload('unsupported_doc_type');
}


if ($folder) {
	$doc = new pikaDocument();
	
	if($doc_type == 'F') {
		$doc->createFolder($folder_name,$parent_folder,$doc_type);
		header("Location: {$base_url}/system-forms.php");
	}elseif ($doc_type == 'C' && is_numeric($case_id)){
		$doc->createFolder($folder_name,$parent_folder,$doc_type,$case_id);
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen=docs");
	}elseif ($doc_type == 'R'){
		$doc->createFolder($folder_name,$parent_folder,$doc_type,$report_name);
		header("Location: {$base_url}/reports/$report_name/");
	}else {  // Unknown Type - back to home screen
		header("Location: {$base_url}");
	}
}

else {
	if (is_array($file_array['name'])) {
		foreach ($file_array['name'] as $key => $value)
		{
			$doc = new pikaDocument();
			$x = array('name' => $value,
					   'type' => $file_array['type'][$key],
					   'tmp_name' => $file_array['tmp_name'][$key],
					   'error' => $file_array['error'][$key]);
			$doc->uploadDoc($x, $description, $parent_folder, $doc_type, $case_id);
		}
	}
	
	else {
		$doc = new pikaDocument();
		$doc->uploadDoc($file_array, $description, $parent_folder, $doc_type, $case_id);
	}
	
	if($doc_type == 'C' && is_numeric($case_id)) {
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen=docs");
	} elseif($doc_type == 'F') {
		header("Location: {$base_url}/system-forms.php");
	} else {  // Unknown Type - back to home screen
		header("Location: {$base_url}");
	}
	
}

?>