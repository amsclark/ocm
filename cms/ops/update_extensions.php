<?php

/**********************************/
/* Pika CMS (C) 2012 Aaron Worley */
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


// VARIABLES
$base_url = pl_settings_get('base_url');
$dummy = array();

if (!pika_authorize("system", $dummy))
{
	$plTemplate["content"] = "Permission denied";
	$plTemplate["page_title"] = "System Operations";
	$plTemplate["nav"] = "<a href=\"{$base_url}/\" class=light>$pikaNavRootLabel</a> &gt; System Operations";
	
	/*	echo, not a bare call: pl_template() returns the page rather than
		printing it, so this refusal was built and discarded and the
		request answered 200 with an empty body. Same defect, and the same
		note, as cms/system-ops.php. The gate held either way -- exit()
		stops the request before anything is written.
	*/
	echo pl_template($plTemplate, 'templates/default.html');
	echo pl_bench('results');
	exit();
}

// BEGIN MAIN CODE...
// The user is updating the extensions settings.

$i = 0;
$j = $site_map_urls = $site_map_titles = $home_page_urls = $home_page_titles = "";
$report_urls = $report_titles = "";

foreach ($_POST as $key => $val)
{
	/*	$key is a POST field name, so it is whatever the request chose to
		send, and everything this loop builds from it is a path or an
		allowlist entry: pm.php gates a require() on the 'extensions'
		setting written below.
		
		pl_csrf_check() leaves its own fields in $_POST, so '_csrf' and
		'_csrf_recovery' were about to be recorded as installed extensions.
		
		Past that, hold the name to the shape the folder scan in
		system-extensions.php produces -- one or more '/name' segments of
		plain characters -- so a name cannot carry a traversal sequence, a
		path separator, a null byte, or the ':' that separates entries in
		the setting itself.
	*/
	if ('_csrf' === $key || '_csrf_recovery' === $key)
	{
		continue;
	}
	
	$key_ok = (bool) preg_match('#^(/[A-Za-z0-9._\-]+)+$#', (string) $key);
	
	foreach (explode('/', (string) $key) as $key_segment)
	{
		if ('.' === $key_segment || '..' === $key_segment)
		{
			$key_ok = false;
		}
	}
	
	if (!$key_ok)
	{
		continue;
	}
	
	if ($i == 0)
	{
		$j .= $key;
	}
	
	else
	{
		$j .= ":" . $key;
	}
	
	$i++;
	$manifest = pl_custom_directory() . "/extensions" . $key . "/manifest.txt";
	
	if (file_exists($manifest) && is_readable($manifest))
	{
		$ini = parse_ini_file($manifest);
		
		if (array_key_exists('site_map_url', $ini))
		{
			$site_map_urls .=  $key . "/" . $ini['site_map_url'] . ":";
			
			if (pl_array_lookup('show_on_home_page', $ini) == 'true' || true)
			{
				$home_page_urls .= $key . "/" . $ini['site_map_url'] . ":";
			}
		}
		
		if (array_key_exists('site_map_title', $ini))
		{
			$site_map_titles .= $ini['site_map_title'] . ":";

			if (pl_array_lookup('show_on_home_page', $ini) == 'true' || true)
			{
				$home_page_titles .= $key . $ini['site_map_url'] . ":";
			}
		}
	}
	
	else
	{
		$report_urls .= "{$key}/index.php:";
		$report_titles .= trim(file_get_contents(pl_custom_directory() . "/extensions" . $key . "/title.txt")) . ":";
	}
}

pl_settings_set('extensions', $j);
pl_settings_set('extensions_site_map_urls', $site_map_urls);
pl_settings_set('extensions_site_map_titles', $site_map_titles);
pl_settings_set('extensions_home_page_urls', $home_page_urls);
pl_settings_set('extensions_home_page_titles', $home_page_titles);
pl_settings_set('extensions_report_urls', $report_urls);
pl_settings_set('extensions_report_titles', $report_titles);
pl_settings_save() or trigger_error('Couldn\'t save settings');

header("Location: {$base_url}/system-extensions.php");
exit();

?>