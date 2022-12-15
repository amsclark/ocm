<?php

chdir('..');
require_once('pika-danio.php');

pika_init();

require_once('pikaDocument.php');
require_once('pikaMisc.php');

if ( $_SERVER['REQUEST_METHOD'] === 'POST' ){ 
        $postText = file_get_contents('php://input'); 
}
$report_name = pl_grab_get('report_name');
$doc_name = pl_grab_get('doc_name');
$report_list = pikaMisc::reportList();
$xml_doc = new DOMDocument();
if($xml_doc->loadXML($postText)){
	if($report_name) {
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
		
		
		foreach ($result as $node) {
			if(strlen($node->nodeValue)) {
				$report_file_name = $node->nodeValue;
			}
		}
		$doc->doc_name = $report_file_name;
		$doc->report_name = $report_name;
		$doc->description = $report_name . " saved " . date('m/d/Y');
		$doc->mime_type = 'text/xml';
		$doc->doc_type = 'R';
		$doc->doc_size = $doc_size;
		$doc->user_id = $auth_row['user_id'];
		$doc->created = date('Y-m-d');
		$doc->save();
	}
	
}


