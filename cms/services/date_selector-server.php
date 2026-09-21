<?php

/**********************************/
/* Pika CMS (C) 2008 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

/*	A session is required here. This endpoint ran with
	PL_DISABLE_SECURITY, which tells pika_init() to skip authenticate()
	altogether, so anyone who could reach the server could reach it --
	no account, no cookie. Nothing it serves is meant to be public.
	
	PL_DISABLE_DISPLAY_LOGIN is what makes that safe to fix without
	breaking the caller: pika_init() authenticates as it does on every
	other page, and a request with no session ends with an empty body
	rather than a login page rendered where a reply was expected. The
	same pair is used by cms/documents.php.
*/
define('PL_DISABLE_DISPLAY_LOGIN',true);

chdir('..');
require_once('pika-danio.php');
pika_init();

require_once('pikaTempLib.php');

$field_name = pl_grab_get('field_name');
$field_value = pl_grab_get('field_value');
$container = pl_grab_get('container');
$month = pl_grab_get('month');
$year = pl_grab_get('year');

// field_name is echoed back into HTML attributes by the date_selector plugin,
// which escapes it -- but an injection point should not rest on output escaping
// alone, so pin the input to the shape a form field name can legitimately
// have. This runs after the session check above, so a stranger never reaches
// it at all; a signed-in caller still cannot put anything else here. Every
// caller is either a template field (act_date, open_date ...) or a custom
// field (column_name / cf_<field_key>), all of which validate upstream to
// [A-Za-z0-9_-] and 64 chars or fewer; brackets are allowed so array-style
// names like foo[1] keep working.
if (!preg_match('/^[A-Za-z0-9_\[\]-]{1,64}\z/', (string)$field_name))
{
	header('Content-Type: text/plain; charset=UTF-8', true, 400);
	exit('Invalid field_name.');
}

// The container is a DOM id we generate ourselves as "date_selector-NNNNN";
// hold it to the same shape for the same reason.
if (!preg_match('/^[A-Za-z0-9_-]{1,64}\z/', (string)$container))
{
	header('Content-Type: text/plain; charset=UTF-8', true, 400);
	exit('Invalid container.');
}

$buffer = pikaTempLib::plugin('date_selector',$field_name,$field_value,$container,array("month={$month}","year={$year}"));

exit($buffer);
?>
