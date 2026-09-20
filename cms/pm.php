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

/*	Decode before stripping, then refuse anything that still holds '..'.

	The single str_replace() this file used to rely on runs once, so a
	sequence written to survive it - '...//' collapses to '..//' - walked
	through. Strip, then check: if a traversal sequence is still there after
	the strip, the request was built to defeat the strip and there is nothing
	to salvage. The urldecode() is for a SAPI that hands PHP_SELF over
	without decoding it; where PHP_SELF is already decoded, decoding again is
	harmless because every path segment is then held to the character set
	below.
*/
$package_str = urldecode($package_str);
$package_str = str_replace('..', '', $package_str);

if (strpos($package_str, '..') !== false)
{
	trigger_error("Path traversal detected.");
}

$uri = explode('/', $package_str);

/*	An extension directory or file name is a plain name. Refuse a segment
	holding anything else, so a name cannot carry a separator, a quote, a null
	byte or the comma that separates entries in the 'extensions' setting.
*/
foreach ($uri as $uri_segment)
{
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

	$_GET and $_POST are both read, rather than $_REQUEST or one pl_grab_*()
	call, because the extension chooses its own getter and the two can disagree.
	With request_order at its "GP" default a POST body wins in $_REQUEST, so

		POST pm.php/reports/<ext>/<file>.php?case_id=42
		case_id=

	left a $_REQUEST gate reading blank while an extension calling
	pl_grab_get('case_id') still read case 42. Measured on the same stack, on
	both branches. Two different non-blank values are refused rather than
	ranked, because there is no way to know here which one the extension will
	read.

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
$pm_case_ids = array();
$pm_case_id_unusable = false;

foreach (array($_GET, $_POST) as $pm_source)
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

	$pm_value = (string) $pm_source['case_id'];

	if ('' !== $pm_value)
	{
		$pm_case_ids[] = $pm_value;
	}
}

if ($pm_case_id_unusable || 0 < count($pm_case_ids))
{
	$pm_base_url = pl_settings_get('base_url');

	if ($pm_case_id_unusable || 1 < count(array_unique($pm_case_ids)))
	{
		pl_case_not_viewable($pm_base_url);
	}

	$pm_case_id = filter_var($pm_case_ids[0], FILTER_VALIDATE_INT,
		array('options' => array('min_range' => 1)));

	if (false === $pm_case_id)
	{
		pl_case_not_viewable($pm_base_url);
	}

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
/*	The three require() calls in this file build their target out of the
	request path. The only filter above is a str_replace('..',''), which a
	path like '.../...//' walks straight through. Two rules close that:
	the extension directory must appear in the 'extensions' setting, and
	the included file must end in .php. That is CWE-98 (PHP file
	inclusion) on all three call sites.
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
			$x = pl_custom_directory() . "/extensions/" . $ext_name . '/' . $uri[3];
		}
		
		else
		{
			$x = pl_custom_directory() . "/extensions/" . $ext_name . '/' . $uri[3] . '/' . $uri[4];
		}
		
		// Only a .php file may be included, whatever the path segments say.
		if (substr($x, -4) !== '.php')
		{
			trigger_error("Report target must be a .php file.");
		}
		
		chdir('app/lib');
		require($x);
	}
}

else 
{
	array_shift($uri);
	$filepath = array_shift($uri);
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
	
	if (!in_array($filepath, $enabled_extensions, true))
	{
		trigger_error("Extension '{$filepath}':'{$filename}' is either not enabled or not installed.");
	}
	
	// Only a .php file may be included, whatever the path segments say.
	if (substr($filename, -4) !== '.php')
	{
		trigger_error("Extension target must be a .php file.");
	}
	
	require(pl_custom_directory() . "/extensions/{$filepath}/{$filename}");
}

/*	pika_exit() takes the page body to print. Called with no argument it
	raised ArgumentCountError, so every extension that loaded successfully
	printed its output and then ended the request with HTTP 500. The
	extension has already printed whatever it wanted, so pass an empty body.
*/
pika_exit('');
?>
