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
require_once('pikaContact.php');


// VARIABLES
$case_id = pl_grab_post('case_id', 0);
$relation_code = pl_grab_post('relation_code');
$screen = pl_grab_var('screen', 'REQUEST', 'act');
$base_url = pl_settings_get('base_url');

// BEGIN MAIN CODE...
// An existing contact record is being added to this case
// A new contact record is being added to this case.

if (is_null($case_id) || is_null($relation_code))
{
	trigger_error('Ran into trouble when adding the case contact');
}

$case1 = new pikaCase($case_id);
$contact = new pikaContact();
$contact->setValues($_POST);

// take care of those nasty "masked" fields
/*
if (isset($_POST['phone_a']) || isset($_POST['phone_b']))
{
	$a["phone"] = "$phone_a-$phone_b";
}

else if (!isset($a['phone']))
{
	$a["phone"] = "";
}

if (isset($_POST['phone_alt_a']) || isset($_POST['phone_alt_b']))
{
	$a["phone_alt"] = "$phone_alt_a-$phone_alt_b";
}

else if (!isset($a['phone_alt']))
{
	$a["phone_alt"] = "";
}

if ($_POST['ssn0'] || $_POST['ssn1'] || $_POST['ssn2'])
{
	$a['ssn'] = "{$_POST['ssn0']}-{$_POST['ssn1']}-{$_POST['ssn2']}";
}

else if (!isset($a['ssn']))
{
	$a['ssn'] = "";
}
*/

$contact_id = $contact->getValue('contact_id');
$case1->addContact($contact_id, $relation_code);
$contact->save();
header("Location: {$base_url}/contact.php?contact_id={$contact_id}&case_id={$case_id}&screen={$screen}");
exit();

?>