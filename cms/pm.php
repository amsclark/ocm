<?php

/**********************************/
/* Pika CMS (C) 2012 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

/* TODO

	The apache config trick (Alias /p6/in-out.php ...) did not work when the site was moved to ps9.
	Is there another, more portable way to do this in Apache?
	
	Should I restrict extensions to only one-deep folders to make it easier to secure and easier
	to reference code in other extensions?  The downside is it will be harder for inexperienced
	users to install extensions on their own.

*/


require_once ('pika-danio.php');
pika_init();

// Ex:  '/org/pm.php/project/form.php'
$package_str = str_replace($_SERVER['SCRIPT_NAME'], "", $_SERVER['PHP_SELF']); 
// Now '/project/form.php'

/*	Decode before checking each path segment. Refuse invalid names instead
	of changing them, so 'a..b.php' cannot select 'ab.php'. The urldecode()
	also covers a SAPI that leaves PHP_SELF encoded.
*/
$package_str = urldecode($package_str);

$uri = explode('/', $package_str);

/*	An extension directory or file name is a plain name. Refuse a segment
	holding anything else, so a name cannot carry a separator, a quote, a null
	byte or the comma that separates entries in the 'extensions' setting.
*/
foreach ($uri as $uri_segment)
{
	if ('.' === $uri_segment || strpos($uri_segment, '..') !== false)
	{
		trigger_error("Path traversal detected.");
	}
	
	if ('' !== $uri_segment && preg_match('/[^a-zA-Z0-9._\-]/', $uri_segment))
	{
		trigger_error("Invalid path component.");
	}
}

/*
var_dump($uri);
pika_exit();
*/
/*	Read access to the case is checked here, before either branch below
	includes anything.

	Both require() calls load a deployment's own extension code, which is not in
	this repository, so nothing here can make that code hold a gate. Until this
	check, pm.php asked only pika_init() - is the caller signed in - and then
	handed the request, case_id and all, to the extension. Measured on a
	throwaway stack with an extension that prints a case number: a signed-in user
	whose group grants no case access read the number of a case that case.php
	answers 403 for, on the reports path and on the plain one.

	The check has to run before the chdir('app/lib') in the reports branch as
	well. pl_case_not_viewable() reads templates/default.html by a relative path,
	so from app/lib it would find no template.

	Every request source is read, not one of them and not $_REQUEST alone,
	because the extension chooses its own getter and the sources can disagree.
	One gate reading $_REQUEST is not enough:

		POST pm.php/reports/<ext>/<file>.php?case_id=42
		case_id=

	leaves a $_REQUEST gate reading blank on a GP request_order while an
	extension calling pl_grab_get('case_id') still reads case 42. Reading only
	$_GET and $_POST is not enough either, and is worse: request_order is unset
	in the container this repository ships, so $_REQUEST is built in
	variables_order, EGPCS, and a cookie overwrites both. Measured on that
	runtime: with ?case_id=7, a body of case_id=99 and a Cookie of case_id=42,
	$_REQUEST holds 42. So a cookie alone can hand an extension a case that
	nothing on the query string or in the body ever named.

	Every distinct id any source names has to pass, so there is nothing to rank
	and no need to guess which getter the extension uses. Two spellings of one
	readable case, '42' and ' 42 ', are one id and are allowed: the getters trim
	and so does filter_var(). Two genuinely different ids are both checked, and
	one unreadable id refuses the request however many readable ones accompany
	it.

	A request that names no case is unaffected: with no case_id there is nothing
	to check, and an extension that reports across cases still runs.

	A case_id that is not a positive integer, or that names no case, gets the
	same refusal as a case the caller may not read, so the answer cannot be used
	to tell real case numbers from invented ones. This is the rule
	legacy_report.php uses, for the same reason. An extension that passes 0 to
	mean "no case" should pass nothing instead.

	This gate covers the case_id parameter. What an extension does with any
	other parameter it is handed is in the deployment's own code, which this
	repository does not carry and these checks cannot speak for.
*/
$pm_case_values = array();
$pm_case_id_unusable = false;

/*	$_REQUEST is read as well as the three it is built from. It is the value
	pl_grab_var() returns, and on a runtime that leaves request_order unset it
	can differ from every one of them.
*/
foreach (array($_GET, $_POST, $_COOKIE, $_REQUEST) as $pm_source)
{
	if (!isset($pm_source['case_id']))
	{
		continue;
	}

	/*	An array, as ?case_id[]=42 sends, is not a case id at all. Skipping it
		would leave the gate silent about a parameter the extension still sees.
	*/
	if (!is_scalar($pm_source['case_id']))
	{
		$pm_case_id_unusable = true;
		continue;
	}

	/*	Trimmed before the empty test, so that a case_id of one space is
		treated the same way as an empty one. The getters trim as well, so
		neither of them names a case.
	*/
	$pm_value = trim((string) $pm_source['case_id']);

	if ('' === $pm_value)
	{
		continue;
	}

	/*	filter_var() refuses a decimal written with leading zeros, but every
		reader of case_id casts to int, and (int) '042' is 42. Refusing the
		request would refuse a case the caller is allowed to read, so drop the
		zeros here and let the validation below see the number they wrote.
	*/
	if (preg_match('/^\+?0+[0-9]+$/', $pm_value))
	{
		$pm_value = ltrim(ltrim($pm_value, '+'), '0');
	}

	$pm_case_values[] = $pm_value;
}

if ($pm_case_id_unusable || 0 < count($pm_case_values))
{
	$pm_base_url = pl_settings_get('base_url');

	if ($pm_case_id_unusable)
	{
		pl_case_not_viewable($pm_base_url);
	}

	$pm_case_seen = array();

	foreach ($pm_case_values as $pm_value)
	{
		$pm_case_id = filter_var($pm_value, FILTER_VALIDATE_INT,
			array('options' => array('min_range' => 1)));

		if (false === $pm_case_id)
		{
			pl_case_not_viewable($pm_base_url);
		}

		if (isset($pm_case_seen[$pm_case_id]))
		{
			continue;
		}

		$pm_case_seen[$pm_case_id] = true;

		$pm_result = DB::query("SELECT * FROM cases WHERE case_id = "
			. (int) $pm_case_id . " LIMIT 1");

		if (!$pm_result || DBResult::numRows($pm_result) < 1)
		{
			pl_case_not_viewable($pm_base_url);
		}

		if (!pika_authorize('read_case', DBResult::fetchRow($pm_result)))
		{
			pl_case_not_viewable($pm_base_url);
		}
	}
}

if ($uri[0] != '') 
{
	trigger_error("General URL error.");
}
/*
if (sizeof($uri) == 3)
{
	var_dump($uri);
}
*/
/*	Both require() calls use a resolved path inside an enabled extension.
	The target must be a regular .php file. Checking the resolved path also
	refuses a symlink that points outside that extension directory.
*/
else if ($uri[1] == 'reports')
{
	/*	pl_enabled_extensions() in app/lib/pl.php is the one parser for this
		setting, and explains the shape it is stored in. The two branches in
		this file used to parse it here, each splitting on ',' and comparing
		against a name with no leading slash, so in_array() below was false
		for every request and no extension could be reached at all.
	*/
	$enabled_extensions = pl_enabled_extensions();
	
	if (sizeof($uri) == 4 || sizeof($uri) == 5)
	{
		$ext_name = $uri[2];
		
		if (!in_array($ext_name, $enabled_extensions, true))
		{
			trigger_error("Extension '{$ext_name}' is either not enabled or not installed.");
		}
		
		if (sizeof($uri) == 4)
		{
			$target = pl_custom_directory() . "/extensions/" . $ext_name . '/' . $uri[3];
		}
		
		else
		{
			$target = pl_custom_directory() . "/extensions/" . $ext_name . '/' . $uri[3] . '/' . $uri[4];
		}
		
		$real = realpath($target);
		$base = realpath(pl_custom_directory() . '/extensions/' . $ext_name);
		
		if (false === $real || false === $base || !is_file($real)
			|| substr($real, -4) !== '.php'
			|| strpos($real, $base . DIRECTORY_SEPARATOR) !== 0)
		{
			trigger_error("Report target must be a .php file inside its extension directory.");
		}
		
		chdir('app/lib');
		require($real);
	}
}

else 
{
	array_shift($uri);
	$ext_name = array_shift($uri);
	$filename = array_shift($uri);
	
	/*	Match the extension name against the 'extensions' setting exactly.
		
		strpos() asked whether the requested name appears anywhere in the
		setting, so with 'extensions' set to 'billing' a request for the
		directory 'bill' passed the check, and with two entries the whole
		string 'billing,intake' passed as one name. The reports branch above
		already compares against the parsed list; do the same here.
	*/
	/*	pl_enabled_extensions() in app/lib/pl.php is the one parser for this
		setting, and explains the shape it is stored in. The two branches in
		this file used to parse it here, each splitting on ',' and comparing
		against a name with no leading slash, so in_array() below was false
		for every request and no extension could be reached at all.
	*/
	$enabled_extensions = pl_enabled_extensions();
	
	if (!in_array($ext_name, $enabled_extensions, true))
	{
		trigger_error("Extension '{$ext_name}':'{$filename}' is either not enabled or not installed.");
	}
	
	$target = pl_custom_directory() . "/extensions/{$ext_name}/{$filename}";
	$real = realpath($target);
	$base = realpath(pl_custom_directory() . '/extensions/' . $ext_name);
	
	if (false === $real || false === $base || !is_file($real)
		|| substr($real, -4) !== '.php'
		|| strpos($real, $base . DIRECTORY_SEPARATOR) !== 0)
	{
		trigger_error("Extension target must be a .php file inside its extension directory.");
	}
	
	require($real);
}

/*	pika_exit() takes the page body to print. Called with no argument it
	raised ArgumentCountError, so every extension that loaded successfully
	printed its output and then ended the request with HTTP 500. The
	extension has already printed whatever it wanted, so pass an empty body.
*/
pika_exit('');
?>
