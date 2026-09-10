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
$case_id = pl_grab_post('case_id', 0);
$relation_code = pl_grab_post('relation_code');
$contact_id = pl_grab_post('thiscon');
$screen = pl_grab_var('screen', 'REQUEST', 'act');
$base_url = pl_settings_get('base_url');

// BEGIN MAIN CODE...
// An existing contact record is being added to this case
	
if (is_null($case_id))
{
	trigger_error('Ran into trouble when adding the case contact');
}

if (is_null($relation_code))
{
	trigger_error('Ran into trouble when adding the case contact');
}

$case1 = new pikaCase($case_id);

/*	Adding a contact to a case is a change to the case, so ask the same
	question the case screen asks before saving anything. Without it any
	signed-in user could attach a contact to any case by posting its id.
*/
if (!pika_authorize('edit_case',$case1->getValues()))
{
	header("Location: {$base_url}/case.php?case_id={$case_id}");
	exit();
}

$case1->addContact($contact_id, $relation_code);
header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");

exit();

?>