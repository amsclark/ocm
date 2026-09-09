<?php

/************************************/
/* Pika CMS (C) 2015 Aaron Worley   */
/* http://pikasoftware.com          */
/************************************/

require_once('pika-danio.php');
pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

require_once('pikaTempLib.php');

$action = pl_grab_post('action');
$base_url = pl_settings_get('base_url');

$main_html = array();
$main_html['content'] = '';

if (!pika_authorize("system", array()))
{
	$temp["content"] = "Access denied";
	$temp["nav"] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
					 <a href=\"site_map.php\">Site Map</a> &gt;
					 System Maintenance";

	$default_template = new pikaTempLib('templates/default.html',$temp);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}

if (pl_grab_post('plist') == 'Download plist File')
{
	$a = array('script_path' => pl_grab_post('home_path', '', 'text') . "/cms");
	header('Content-Type: text/txt; charset=utf-8');
	header("Content-Disposition: attachment; filename=com.pikasoftware.cms-csv-download.plist");
	echo pl_template('app/scripts/com.pikasoftware.cms-csv-download.plist', $a);
	exit();
}

else if (pl_grab_post('script') == 'Download Script')
{
	$a = array('username' => $auth_row['username'],
				'url' => 'https://' . $_SERVER['HTTP_HOST'] . pl_settings_get('base_url'),
				'save_folder_path' => pl_grab_post('home_path', '', 'text') . "/cms",
				'password' => pl_grab_post('password', '', 'text'));
	header('Content-Type: text/txt; charset=utf-8');
	header("Content-Disposition: attachment; filename=cms-csv-download.php");
	echo pl_template('app/scripts/cms-csv-download.php', $a);
	exit();
}

$template = new pikaTempLib('subtemplates/system-mac_download.html',array());
$main_html['content'] .= $template->draw();
$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
			 <a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
			 System Maintenance";

// Display a screen
$main_html['page_title'] = "System Maintenance";

$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();

pika_exit($buffer);

?>
