<?php

/**********************************/
/* Pika CMS (C) 2009 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

chdir('..');
require_once('pika-danio.php');
pika_init();

require_once('pikaCase.php');

$case_id = pl_grab_get('case_id');

if(!is_numeric($case_id)) { $case_id = ''; }
$case = new pikaCase($case_id);
$case_row = $case->getValues();
$doc = new DOMDocument();
$case_xml = $doc->createElement('pikaCase');
$case_xml = $doc->appendChild($case_xml);


/*	Only emit case fields when the caller actually holds read permission
	on the case, and the case is a real one rather than the empty shell
	pikaCase() hands back for an id with no row.
	
	The else branch used to emit exactly the same XML as the branch
	above it, which made pika_authorize() decide nothing at all. Any
	signed-in user could walk case_id from 1 upwards and read every
	field of every case in the database, including cases in offices
	they have no rights to and cases behind an assignment restriction.
	
	On refusal the answer is an empty <pikaCase/> document, the same
	bytes for every case, so the response body itself says nothing
	about the case that was asked for.
	
	This does not close the wider question of whether an outsider can
	tell which case ids are in use. An id with no row already raises
	the generic Pika error page here, and did so before this change,
	so the two answers are still distinguishable by shape. That is a
	separate defect in how pikaCase reports a missing row and is left
	alone here.
*/
if (pika_authorize('read_case',$case_row) && !$case->is_new)
{
	foreach ($case_row as $field => $value) {
		$case_node = $doc->createElement($field,$value);
		$case_node = $case_xml->appendChild($case_node);
	}
	
} else {
	// Recorded so an operator can see somebody walking case ids. The
	// reason stays in the log and never reaches the response.
	pl_audit('case.read_denied', 'case',
		is_numeric($case_id) ? (int) $case_id : null,
		array('endpoint' => 'services/cases-lookup-ajax.php'));
}


$buffer = $doc->saveXML();
header('Content-type: text/xml');
exit($buffer);
?>
