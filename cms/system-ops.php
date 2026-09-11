<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once ('pika_cms.php');

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}


// initialize variables
$pk = new pikaCms;
$dummy = array();

if (!pika_authorize("system", $dummy))
{
	$plTemplate["content"] = "Permission denied";
	$plTemplate["page_title"] = "System Operations";
	$plTemplate["nav"] = "<a href=\".\" class=light>$pikaNavRootLabel</a> &gt; System Operations";

	pl_template($plTemplate, 'templates/default.html');
	echo pl_bench('results');
	exit();
}

// determine what, if any, action to perform

switch($_POST['action'])
{
	case 'save_menu':

	$i = 0;
	$menu = pl_grab_var('menu', '', 'POST');
	$menu_elements = explode("\n", pl_grab_var('values', '', 'POST'));
	$menu_array = array();

	// build the new, updated menu
	
	foreach ($menu_elements as $key => $val)
	{
		$a = explode("|", $val);

		if (sizeof($a) < 2)
		{
			$a = explode("\t", $val);
		}

		$a[0] = addslashes(trim($a[0]));

		if (isset($a[1]))
		{
			$a[1] = addslashes(trim($a[1]));
		}

		else
		{
			// use the value as both key and label
			$a[1] = $a[0];
		}

		if ('' != $a[0] && '' != $a[1])
		{
			$menu_array[] = array('value' => $a[0], 'label' => $a[1]);
		}
	}

	pl_menu_set($menu, $menu_array);

	header("Location: system-menus.php?screen=edit&menu=$menu");
	exit();

	break;



	case 'old_array_save_menu':

	$menu = $_POST['menu'];

	$menu_elements = explode("\n", $_POST['values']);

	unset($plMenus[$menu]);

	
	
	foreach ($menu_elements as $key => $val)
	{
		$a = explode("=>", $val);

		$a[0] = trim($a[0]);
		$a[1] = trim($a[1]);

		if ('' != $a[0] && '' != $a[1])
		{
			$plMenus[$menu][$a[0]] = $a[1];
		}
	}

	ksort($plMenus);

	pl_save_settings();

	header("Location: system-menus.php");
	exit();

	break;




	case 'add_menu':

	$menu = $_POST['menu'];

	if (isset($plMenus[$menu]))
	{
		die(pika_error_notice("Misc. Error", "There is already a Menu by that name"));
	}

	$menu_elements = explode("\n", $_POST['values']);


	foreach ($menu_elements as $key => $val)
	{
		$a = explode("=>", $val);

		$a[0] = trim($a[0]);
		$a[1] = trim($a[1]);

		if ('' != $a[0] && '' != $a[1])
		{
			$plMenus[$menu][$a[0]] = $a[1];
		}
	}

	ksort($plMenus);

	pl_save_settings();

	header("Location: system-menus.php");
	exit();

	break;


	case 'save_settings':


	foreach ($plSettings as $key => $val)
	{
		$plSettings[$key] = pl_grab_var($key, null, 'POST');
	}

	reset($plSettings);

	pl_settings_save() or die(pika_error_notice('Couldn\'t save settings', 'File permission denied'));

	reset($plSettings);

	header("Location: system-settings.php");
	exit();

	break;

	case 'disable_field';

	unset($plFields[$_POST['table']][$_POST['field']]);

	pl_save_settings();

	header("Location: system-tables.php");
	exit();

	break;


	/*
	case 'save_table':

	$table = $_POST['table'];

	// get list of existing db columns
	$result = pl_query("DESCRIBE $table");
	while ($row = $result->fetchRow())
	{
	$column_names[] = $row['Field'];
	}

	$table_elements = explode("\n", $_POST['values']);

	unset($plFields[$table]);

	while (list($key, $val) = each($table_elements))
	{
	$a = explode("=>", $val);

	$a[0] = trim($a[0]);
	$a[1] = trim($a[1]);

	if ('' != $a[0] && '' != $a[1])
	{
	$plFields[$table][$a[0]] = $a[1];

	// create the column if it doesn't exist
	if (!in_array($a[0], $column_names))
	{
	switch ($a[1])
	{
	case 'date':

	$field_type = "DATE";
	break;

	case 'time':

	$field_type = "TIME";
	break;

	case 'number':

	$field_type = "FLOAT";
	break;

	case 'text':
	default:

	$field_type = "VARCHAR(50)";
	break;
	}

	pl_query("ALTER TABLE $table ADD {$a[0]} $field_type");
	}

	}
	}

	// alphabetize the order of the field lists
	ksort($plFields);

	pl_save_settings();

	header("Location: system-tables.php");
	exit();

	break;
	*/


	case 'assign_default':

	$pikaDvs[$_POST['table']][$_POST['field']] = pl_input_filter($_POST['def_value'], $plFields[$_POST['table']][$_POST['field']]);

	pl_save_settings();

	header("Location: system-tables.php?screen=edit&table={$_POST['table']}");
	exit();

	break;


	case 'add_field':
	case 'assign_type':

	if (in_array($_POST['field_type'], array('text', 'number', 'boolean', 'date')))
	{
		$plFields[$_POST['table']][$_POST['field']] = $_POST['field_type'];

		pl_save_settings();
	}

	header("Location: system-tables.php?screen=edit&table={$_POST['table']}");
	exit();

	break;


	case 'add_group':

	$a = pl_grab_vars('groups');
	$pk->addGroup($a);

	header('Location: system-groups.php');

	break;


	case 'update_group':

	$a = pl_grab_vars('groups');
	$pk->updateGroup($a);

	header('Location: system-groups.php');

	break;





	default:

	die(pika_error_notice("$window_title", "Error:  invalid action was specified."));

	break;
}

// end of 'action' section

exit();

?>
