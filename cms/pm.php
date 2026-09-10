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

$package_str = str_replace('..', '', $package_str);

$uri = explode('/', $package_str);
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
	$enabled_extensions = array_map('trim', explode(',', (string) pl_settings_get('extensions')));
	
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
	
	/*	The same allowlist test the reports branch above already uses. This
		was:
		
			strpos(pl_settings_get('extensions'), $filepath) === false
		
		which asks whether the requested directory name appears ANYWHERE
		inside the setting, not whether it is one of the names in it. Two ways
		that lets code run that the operator did not enable:
		
		  * any substring of the setting passes. With 'extensions' set to
		    'project', cms-custom/extensions/pro was reachable and ran --
		    confirmed live.
		  * an empty segment passes, because PHP 8 returns 0, not false, for
		    strpos() with an empty needle. That reached
		    cms-custom/extensions//<file>, i.e. the extensions directory
		    itself, which is outside every installed extension.
		
		in_array() with strict comparison answers the question that was meant:
		is this exactly one of the enabled names. Null and the empty string
		both fail it.
	*/
	$enabled_extensions = array_map('trim', explode(',', (string) pl_settings_get('extensions')));
	
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

pika_exit();
?>
