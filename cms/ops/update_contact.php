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

require_once('pikaContact.php');

$next_tab = pl_settings_get('default_case_tab');

if (is_null($next_tab))
{
	$next_tab = 'elig';
}

// VARIABLES
$base_url = pl_settings_get('base_url');
$contact_id = pl_grab_post('contact_id');
$case_id = pl_grab_post('case_id');
$intake_id = pl_grab_post('intake_id');
$screen = pl_grab_post('screen', $next_tab);

// BEGIN MAIN CODE...

// The user is saving the contact record.

/*	When the save comes from a case screen, the caller must be allowed to
	edit that case. Without this any signed-in user could rewrite a
	contact - a client's name, address, date of birth - by posting a
	contact id.
*/
if ($case_id)
{
	require_once('pikaCase.php');
	$case_check = new pikaCase($case_id);
	
	if (!pika_authorize('edit_case',$case_check->getValues()))
	{
		header("Location: {$base_url}/case.php?case_id={$case_id}");
		exit();
	}
}

$contact = new pikaContact($contact_id);
// The row to write is the one named by $contact_id above. Strip the copy
// of the key out of the body so it cannot also come from the form.
$contact->setValues(pl_strip_protected_columns(pl_clean_form_input($_POST)));
$contact->save();

if ($case_id)
{
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
}

else if ($intake_id)
{
	header("Location: {$base_url}/intakes.php/{$intake_id}/");
}

else 
{
	$contact_id = $contact->getValue('contact_id');
	header("Location: {$base_url}/contact.php?contact_id={$contact_id}");
}

exit();

?>