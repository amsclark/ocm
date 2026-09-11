<?php

/**********************************/
/* Pika CMS (C) 2008 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

// Need to override redirect to login and just display nothing
define('PL_DISABLE_DISPLAY_LOGIN',true);

require_once('pika-danio.php');
pika_init();

require_once('pikaCase.php');
require_once('pikaDocument.php');
require_once('pikaTempLib.php');

// This file serves two kinds of request: read-only screens (download, edit,
// confirm_delete, the file list) that stay GET, and the two state changes
// below (`update`, `delete`) which are now POST + CSRF token. Read each
// parameter from the method that actually carries it, POST body winning, so
// one set of variables serves both shapes and a caller that keeps
// ?action=delete in the query string while POSTing the token still resolves.
$is_post = isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST';

$grab = function ($name, $default = null, $filter = 'nomode') use ($is_post)
{
	if ($is_post && isset($_POST[$name]))
	{
		return pl_grab_post($name, $default, $filter);
	}
	
	return pl_grab_get($name, $default, $filter);
};

/**
 * A hidden _csrf input to append to the `edit` and `confirm_delete`
 * fragments.
 *
 * Those two fragments are the launch points for the `update` and `delete`
 * POSTs, and cms/js/file_list.js reads the token out of the live DOM. It
 * cannot come from the template: subtemplates/documents.html carries no
 * %%[csrf_field]%% tag, and it is one of the files a per-org custom template
 * directory commonly replaces, so a token added there would be missing on
 * exactly the deployments that matter. Stamping it from PHP puts the token in
 * the DOM whenever -- and only when -- one of the two mutating flows is
 * actually on screen, regardless of what the host page renders.
 *
 * Outside the <form> on purpose: updateFile() walks the form's elements to
 * build its request body, and a hidden field in there would be sent twice.
 */
function pl_documents_csrf_stamp()
{
	if (!function_exists('pl_csrf_hidden_input'))
	{
		return '';
	}
	
	return "\n<div data-documents-csrf hidden>" . pl_csrf_hidden_input() . "</div>\n";
}

$container = $grab('container');
$action = $grab('action');
$mode = $grab('mode');


$doc_id = $grab('doc_id');
$folder_ptr = $grab('folder_ptr');
$case_id = $grab('case_id');
$user_id = $grab('user_id');
$report_name = $grab('report_name');
$doc_type = $grab('doc_type');
$folder_field = $grab('folder_field');
$doc_field = $grab('doc_field');

// CSRF. `update` and `delete` used to be driven straight off the query string
// with no token at all: any page that could make a logged-in browser issue a
// GET could rename, re-folder, or destroy a client document by doc_id. Both
// now require a POST carrying the per-session token. Every POST is checked,
// matching the idiom in the other handlers; the read-only actions are
// untouched and stay GET.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if ($is_post)
{
	pl_csrf_check();
}

if (!$is_post && ($action === 'update' || $action === 'delete'))
{
	// Refuse rather than silently falling through to the file-list render, so
	// a stale caller fails loudly instead of looking like it worked.
	header('HTTP/1.1 405 Method Not Allowed');
	header('Allow: POST');
	header('Content-Type: text/plain; charset=utf-8');
	echo "This action must be submitted as a POST with a CSRF token.\n";
	exit();
}


$html = array();
$html['base_url'] = $base_url = pl_settings_get('base_url');

// ID fields - common to all screens
$html['doc_id'] = $doc_id;

$html['case_id'] = $case_id;
$html['user_id'] = $user_id;
$html['report_name'] = $report_name;
$html['mode'] = $user_id;

// Display directives - common to all screens
$html['container'] = $container;
$html['doc_type'] = $doc_type;
$html['mode'] = $mode;
$html['folder_field'] = $folder_field;
$html['doc_field'] = $doc_field;

							
switch($action) {
	case 'download':
		$doc = new pikaDocument($doc_id);
		
		/*	This branch had no permission check at all: any signed-in user
			could read any document in the system by walking doc_id, which on
			a legal aid installation means every client's papers. Documents
			attached to a case are readable by whoever may read the case, so
			load the case row and ask pika_authorize the same question the
			case screen asks. A document with no case_id is not case material
			(a form template, a letterhead) and stays readable.
		*/
		if ($doc->case_id)
		{
			$doc_case = new pikaCase($doc->case_id);
			
			if (!pika_authorize('read_case',$doc_case->getValues()))
			{
				die('Access denied');
			}
		}
		
		$doc_data = gzuncompress(stripslashes($doc->doc_data));
		//$doc_data = stripslashes($doc->doc_data);
		
		/*	Headers built in one place, shared with cms/ops/docgen.php.
			
			It strips the line breaks out of the file name -- the uploader
			chooses that, and a name holding a carriage return splits the
			header block -- and it refuses to serve anything the browser
			would run. The stored MIME type is chosen by whoever uploaded the
			file, and a document uploaded as text/html used to come back as
			text/html and inline, so it executed on this application's origin
			in the reader's session. See sendDownloadHeaders() in
			cms/app/lib/pikaDocument.php.
		*/
		pikaDocument::sendDownloadHeaders($doc->mime_type,$doc->doc_name);
		
		/*	I'm not sure how determine the Content Length if GZIP is being used,
			and Firefox 33 doesn't like it when I send the uncompressed size
			(see bug id 1083090.) */
		//if (pl_settings_get("enable_compression") == false)
		//{
		//	header("Content-Length: " . strlen($doc_data));
		//}
		
		echo $doc_data;
		exit();
	case 'edit':
		$doc = new pikaDocument($doc_id);
		
		/*	confirm_delete, update and delete all ask edit_doc first. This
			branch did not, so the edit form - which shows the name, the
			description and the folder, and is the way in to the update
			action below - opened for any doc_id any signed-in user typed.
		*/
		if (!pika_authorize("edit_doc",$doc->getValues()))
		{
			$template = new pikaTempLib('subtemplates/documents.html',$html,'access_denied');
			$buffer = $template->draw();
			break;
		}
		
		$html['doc_type'] = $doc->doc_type;
		$html['doc_name'] = $doc->doc_name;
		$html['description'] = $doc->description;
		$html['folder_ptr'] =  $doc->folder_ptr;
		if($html['folder_ptr'] == 0)
		{
			$html['folder_ptr'] = '';
		}
		$html['case_id'] = $doc->case_id;
		$html['report_name'] = $doc->report_name;
		
		if($doc->folder != 1)
		{
			$filter = array('doc_type' => $doc->doc_type, 'case_id' => $doc->case_id, 'report_name' => $doc->report_name);
			$folder_list = $doc->getFolderList($filter);
			$menu_folders = array();
			foreach($folder_list as $val) {
				$menu_folders[$val['doc_id']] = $val['doc_name'];
			}
			$template = new pikaTempLib('subtemplates/documents.html',$html,'edit_file');
			$template->addMenu('folder_menu',$menu_folders);
		}
		else 
		{
			$template = new pikaTempLib('subtemplates/documents.html',$html,'edit_folder');
			
		}
		
		$buffer = $template->draw() . pl_documents_csrf_stamp();
		break;
	case 'confirm_delete':
		
		$doc = new pikaDocument($doc_id);
		
		$html['doc_type'] = $doc->doc_type;
		$html['doc_name'] = $doc->doc_name;
		$html['description'] = $doc->description;
		$html['folder_ptr'] =  $doc->folder_ptr;
		$html['case_id'] = $doc->case_id;
		$html['report_name'] = $doc->report_name;
		$html['user_id'] = $doc->user_id;
				
		if (!pika_authorize("edit_doc", $html))
		{
			$template = new pikaTempLib('subtemplates/documents.html',$html,'access_denied');
			$buffer = $template->draw();
			
		}
		else {
			$template = new pikaTempLib('subtemplates/documents.html',$html,'confirm_delete');
			$buffer = $template->draw() . pl_documents_csrf_stamp();
		}
		break;
	case 'update':
		// Read through $grab like every other parameter on this file:
		// `update` is POST-only now, so a straight pl_grab_get() here would
		// silently see an empty name and a NULL description and wipe the
		// metadata it was asked to change.
		$doc_name = $grab('doc_name');
		$description = $grab('description');
		$doc = new pikaDocument($doc_id);
		// Authorization: only persist the metadata change if the caller is
		// allowed to edit this document. Without the gate any authenticated
		// user could rename / re-describe / re-folder any document by doc_id
		// (the `delete` action below already gates the same way; this brings
		// `update` into line).
		if (pika_authorize("edit_doc", $doc->getValues()))
		{
			if(strlen($doc_name) > 0)
			{
				$doc->doc_name = $doc_name;
			}
			$doc->description = $description;
			$doc->folder_ptr = $folder_ptr;
			$doc->save();
		}
		$buffer = 1;
		break;
	case 'delete':
		$doc = new pikaDocument($doc_id);
		if (pika_authorize("edit_doc", $doc->getValues())) {
			if($doc->folder == 1)
			{
				$files = $doc->getFiles($doc->doc_id,$doc->doc_type,$doc->case_id);
				if (count($files) > 0) {
					$doc->moveFiles($doc->folder_ptr,$files);
				}
			}
			$doc->delete();
		}
		$buffer = 1;
		break;
	default:
		$buffer = pikaTempLib::plugin('file_list',$container,$folder_ptr,array(),array("mode={$mode}","doc_type={$doc_type}","folder_field={$folder_field}","doc_field={$doc_field}",'div'),$html);
		break;
}

echo $buffer;
exit();
?>
