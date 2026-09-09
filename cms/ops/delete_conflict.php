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

require_once('pikaCase.php');

// VARIABLES
$conflict_id = pl_grab_var('conflict_id');
$case_id = pl_grab_get('case_id');
$case1 = new pikaCase($case_id);
$base_url = pl_settings_get('base_url');
	
// BEGIN MAIN CODE...
if (pika_authorize('edit_case', $case1->getValues())) 
{
	$case1->removeContact($conflict_id);
}

header("Location: {$base_url}/case.php?case_id={$case_id}&screen=info");
exit();

?>