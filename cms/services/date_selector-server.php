<?php

/**********************************/
/* Pika CMS (C) 2008 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

define('PL_DISABLE_SECURITY',true);

chdir('..');
require_once('pika-danio.php');
pika_init();

require_once('pikaTempLib.php');

$field_name = pl_grab_get('field_name');
$field_value = pl_grab_get('field_value');
$container = pl_grab_get('container');
$month = pl_grab_get('month');
$year = pl_grab_get('year');

// This endpoint runs with PL_DISABLE_SECURITY, so anyone who can reach the
// server can reach it without a session. field_name is echoed back into HTML
// attributes by the date_selector plugin, which escapes it -- but an
// unauthenticated injection point should not rest on output escaping alone, so
// pin the input to the shape a form field name can legitimately have. Every
// caller is either a template field (act_date, open_date ...) or a custom
// field (column_name / cf_<field_key>), all of which validate upstream to
// [A-Za-z0-9_-] and 64 chars or fewer; brackets are allowed so array-style
// names like foo[1] keep working.
if (!preg_match('/^[A-Za-z0-9_\[\]-]{1,64}$/', (string)$field_name))
{
	header('Content-Type: text/plain; charset=UTF-8', true, 400);
	exit('Invalid field_name.');
}

// The container is a DOM id we generate ourselves as "date_selector-NNNNN";
// hold it to the same shape for the same reason.
if (!preg_match('/^[A-Za-z0-9_-]{1,64}$/', (string)$container))
{
	header('Content-Type: text/plain; charset=UTF-8', true, 400);
	exit('Invalid container.');
}

$buffer = pikaTempLib::plugin('date_selector',$field_name,$field_value,$container,array("month={$month}","year={$year}"));

exit($buffer);
?>
