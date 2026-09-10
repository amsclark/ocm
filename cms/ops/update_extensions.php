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
	
	pl_template($plTemplate, 'templates/default.html');
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