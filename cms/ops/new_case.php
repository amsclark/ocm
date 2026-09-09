<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

chdir('../');
require_once ('pika-danio.php');
pika_init();

// This page performs its state changes on a GET: the action is dispatched
// out of the query string and the links that trigger it are plain <a href>
// markup, so a hidden token field is not available as a defence here.
// On a non-POST request pl_csrf_check() falls through to the same-site
// check, which refuses a mutation that a foreign page initiated and needs
// nothing from the markup. See pl_request_cross_site_verdict() in pl.php.
pl_csrf_check();


// LIBRARIES
require_once('pikaCase.php');


// VARIABLES
$thiscon = pl_grab_get('thiscon');
$base_url = pl_settings_get('base_url');
$screen = pl_grab_get('screen', 'elig');
$safe_screen = pl_clean_html($screen);


// BEGIN MAIN CODE...

/*  The user is coming from intake2.php, and wants to create a new case
for an existing contact.  Don't import any data from previous cases, however.
*/

// add the case record...
$case1 = new pikaCase();
$case1->setValues(pl_clean_form_input($_GET));
// Now link the client to the case and set the first client as the primary client
$case1->addContact($thiscon, 1);

/*	Go directly into the eligibility tab.
*/
$case_id = $case1->getValue('case_id');
header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
exit();

?>