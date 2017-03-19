<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('pika-danio.php');
pika_init();

require_once('pikaMisc.php');

$base_url = pl_settings_get('base_url');
$main_html = array();  // Values for the main HTML template.
$main_html['reportlist'] = pikaMisc::htmlReportList();
$main_html['page_title'] = "Site Map";

// AMW 2012-11-20 
$ext_urls = explode(":", pl_settings_get('extensions_site_map_urls'));
$ext_titles = explode(":", pl_settings_get('extensions_site_map_titles'));
// 2013-08-13 AMW - These two lines eliminate the blank ghost entry at the bottom of the extensions list.
array_pop($ext_urls);
array_pop($ext_titles);


if (sizeof($ext_titles) > 0 || true)
{
	$main_html['extensions_list'] = "<h2>Extensions</h2><ul>"; // Brian removed BR
	
	for ($i =0; $i < sizeof($ext_urls); $i++)
	{
		$main_html['extensions_list'] .= "<li><a href=\"{$base_url}/pm.php{$ext_urls[$i]}\">{$ext_titles[$i]}</a></li>";
	}
	
	$main_html['extensions_list'] .= "</ul>";
}
// End AMW

$main_html['content'] =  pl_template('subtemplates/site_map.html', $main_html);
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> <span class=\"nav-arrow\">&#10140;</span> Site Map";

$buffer = pl_template('templates/default.html', $main_html);
pika_exit($buffer);
?>
