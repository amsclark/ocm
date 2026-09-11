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
	/*	array_filter() drops the empty entry that explode() returns for an
		unset setting, so a request naming no extension at all cannot match
		it.
	*/
	$enabled_extensions = array_filter(
		array_map('trim', explode(',', (string) pl_settings_get('extensions'))), 'strlen');
	
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
	/*	array_filter() drops the empty entry that explode() returns for an
		unset setting, so a request naming no extension at all cannot match
		it.
	*/
	$enabled_extensions = array_filter(
		array_map('trim', explode(',', (string) pl_settings_get('extensions'))), 'strlen');
	
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
