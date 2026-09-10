<?php

/**********************************/
/* Pika CMS (C) 2010 			  */
/* http://pikasoftware.com		  */
/**********************************/

require_once('pika-danio.php');
pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}
require_once('pikaTempLib.php');
require_once('pikaSettings.php');
require_once('pikaDefPrefs.php');

$main_html = $html = array();
$main_html["page_title"] = $title = "User Default Preferences";

$prefs = pikaDefPrefs::getInstance();
$settings = pikaSettings::getInstance();
$base_url = $settings['base_url'];

$action = pl_grab_post('action');

if (!pika_authorize("system", $dummy))
{
	$main_html["content"] = "Access denied";
	$main_html["nav"] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; 
						<a href=\"{$base_url}/site_map.php\">Site Map</a> &gt; 
						{$title}";

	$buffer = pl_template('templates/default.html',$main_html);
	pika_exit($buffer);
}


$r_format = array(	'pdf' => 'PDF',
					'html' => 'HTML');
$font_size = array(	'Small' => 'Small',
					'Medium' => 'Medium',
					'Large' => 'Large',
					'Super Size' => 'Super Size');

$ical_interval = array(	'7' => '7 Days',
						'14' => '14 Days',
						'30' => '30 Days',
						'60' => '60 Days');

$rss_interval = array(	'1' => '1 Day',
						'5' => '5 Days',
						'7' => '7 Days',
						'14' => '14 Days',
						'30' => '30 Days');
						

switch ($action)
{
	case 'update_prefs':
		foreach ($prefs as $pref_name => $pref_value)
		{
			if(isset($_POST[$pref_name]) && $_POST[$pref_name] != $prefs[$pref_name])
			{
				$prefs[$pref_name] = $_POST[$pref_name];
			}
		}
		$prefs->save();
		
	default:
		if(!$prefs->isWritable()) {
			$html['flags'] = pikaTempLib::plugin('red_flag','red_flag','Default Preferences file is not writeble by Pika - Entries may not save properly!');
		}
		foreach ($prefs as $pref_name => $pref_value)
		{
			$html[$pref_name] = $pref_value;
		}
		// Use single prefs form for both defaults and user prefs (to carry changes easily)
		$prefs_template = new pikaTempLib('subtemplates/prefs_form.html',$html,'prefs_form');
		$prefs_template->addMenu('r_format',$r_format);
		$prefs_template->addMenu('font_size',$font_size);
		$prefs_template->addMenu('ical_interval',$ical_interval);
		$prefs_template->addMenu('rss_interval',$rss_interval);
		$html['prefs_form'] = $prefs_template->draw();
		
		
		$template = new pikaTempLib('subtemplates/system-default_prefs.html',$html,'edit');
		
		$main_html['content'] = $template->draw();
		$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; 
						<a href=\"{$base_url}/site_map.php\">Site Map</a> &gt; 
						{$title}";
		break;
}



$buffer = pl_template($main_html, 'templates/default.html');
pika_exit($buffer);

?>