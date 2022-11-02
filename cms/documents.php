<?php

/**********************************/
/* Pika CMS (C) 2008 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

// Need to override redirect to login and just display nothing
define('PL_DISABLE_DISPLAY_LOGIN',true);

require_once('pika-danio.php');
pika_init();

require_once('pikaDocument.php');
require_once('pikaTempLib.php');

$container = pl_grab_get('container');
$action = pl_grab_get('action');
$mode = pl_grab_get('mode');


$doc_id = pl_grab_get('doc_id');
$folder_ptr = pl_grab_get('folder_ptr');
$case_id = pl_grab_get('case_id');
$user_id = pl_grab_get('user_id');
$report_name = pl_grab_get('report_name');
$doc_type = pl_grab_get('doc_type');
$folder_field = pl_grab_get('folder_field');
$doc_field = pl_grab_get('doc_field');


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
		$doc_data = gzuncompress(stripslashes($doc->doc_data));
		//$doc_data = stripslashes($doc->doc_data);

		header("Pragma: public");
		header("Cache-Control: cache, must-revalidate");
		header("Content-type: application/force-download");
		header("Content-Type: {$doc->mime_type}");
		header("Content-Disposition: inline; filename=\"{$doc->doc_name}\"");
		
		/*	I'm not sure how determine the Content Length if GZIP is being used,
			and Firefox 33 doesn't like it when I send the uncompressed size
			(see bug id 1083090.) */
		//if (pl_settings_get("enable_compression") == false)
		//{
		//	header("Content-Length: " . mb_strlen($doc_data));
		//}
		
		echo $doc_data;
		exit();
	case 'edit':
		$doc = new pikaDocument($doc_id);
		
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
		
		$buffer = $template->draw();
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
			$buffer = $template->draw();
		}
		break;
	case 'update':
		$doc_name = pl_grab_get('doc_name');
		$description = pl_grab_get('description');
		$doc = new pikaDocument($doc_id);
		if(strlen($doc_name) > 0)
		{
			$doc->doc_name = $doc_name;
		}
		$doc->description = $description;
		$doc->folder_ptr = $folder_ptr;
		$doc->save();
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
