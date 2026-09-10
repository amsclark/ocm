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
// Read from POST only. Detaching a party from a case used to ride on a
// GET -- the callers in subtemplates/case_screen.html were plain <a href>
// links -- so anything that could make a logged-in browser issue that URL
// (an <img src> on a foreign page, a link in an email) removed a client or
// an opposing party with no token to stop it. The callers now submit a
// POST form carrying %%[csrf_field]%%; reading the ids with pl_grab_post
// means a GET that still reaches this file has nothing to act on, which is
// the same belt-and-braces shape ops/delete_contact.php and
// ops/delete_activity.php use.
$conflict_id = pl_grab_post('conflict_id');
$case_id = pl_grab_post('case_id');
$base_url = pl_settings_get('base_url');
	
// BEGIN MAIN CODE...
// No case id -- i.e. not a POST from the case screen. Constructing a
// pikaCase from a null id and redirecting to case.php with an empty
// case_id would only produce a broken page, so send the user home.
if (!is_numeric($case_id))
{
	header("Location: {$base_url}/");
	exit();
}

$case1 = new pikaCase($case_id);

if (pika_authorize('edit_case', $case1->getValues())) 
{
	$case1->removeContact($conflict_id);
}

header("Location: {$base_url}/case.php?case_id={$case_id}&screen=info");
exit();

?>