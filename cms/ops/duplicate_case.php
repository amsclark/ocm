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

require_once('pikaCase.php');


// VARIABLES
$case_id = pl_grab_get('case_id');


$case1 = new pikaCase($case_id);
$base_url = pl_settings_get('base_url');

// BEGIN MAIN CODE...
$dup = $case1->duplicate();
$dup_case_id = $dup->getValue('case_id');
header("Location: {$base_url}/case.php?case_id={$dup_case_id}&screen=info");
exit();

?>