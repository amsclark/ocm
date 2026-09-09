<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

chdir('../');

require_once ('pika-danio.php');
pika_init();

require_once('pikaCase.php');

// VARIABLES
$case_id = pl_grab_get('case_id');
$case1 = new pikaCase($case_id);
$base_url = pl_settings_get('base_url');


// BEGIN MAIN CODE...
if (pika_authorize('delete_case', $case1->getValues())) 
{
	pl_audit('case.delete', 'case', $case_id, array(
		'case_number' => $case1->number,
	));
	$case1->delete();
	header("Location: {$base_url}/");
}

else 
{
	header("Location: {$base_url}/case.php?case_id={$case_id}");
}

exit();

?>