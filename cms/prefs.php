<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
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
require_once('pikaAuth.php');
require_once('pikaUser.php');

$main_html = $html = array();
$session_data = array();
$action = pl_grab_post('action');

$settings = pikaSettings::getInstance();
$base_url = $settings['base_url'];

$auth_row = pikaAuth::getInstance()->getAuthRow();
$user = new pikaUser($auth_row['user_id']);

if($action == 'update_prefs')
{
	$default_prefs = pikaDefPrefs::getInstance()->getValues();
	$default_prefs_fieldnames = array_keys($default_prefs);
	
	$user_prefs = array();
	foreach ($_POST as $field_name => $field_value)
	{
		if(in_array($field_name,$default_prefs_fieldnames))
		{
			$user_prefs[$field_name] = $field_value;
		}
	}	
	$user->session_data = serialize($user_prefs);
	$user->save();
	header("Location: {$base_url}/prefs.php");
	exit();
}


$user_prefs = $user->getUserPrefs();


$r_format = array(	'pdf' => 'PDF',
					'html' => 'HTML');
$font_size = array(	'Small' => 'Small',
					'Medium' => 'Medium',
					'Large' => 'Large',
					'Super Size' => 'Super Size');
$rss_interval = array(	'1' => '1 Day',
						'5' => '5 Days',
						'7' => '7 Days',
						'14' => '14 Days',
						'30' => '30 Days');
						
// Use single prefs form for both defaults and user prefs (to carry changes easily)
$prefs_template = new pikaTempLib('subtemplates/prefs_form.html',$user_prefs,'prefs_form');
$prefs_template->addMenu('r_format',$r_format);
$prefs_template->addMenu('font_size',$font_size);
$prefs_template->addMenu('rss_interval',$rss_interval);
$html['prefs_form'] = $prefs_template->draw();


$template = new pikaTempLib('subtemplates/prefs.html',$html,'edit');
$main_html['content'] = $template->draw();

$main_html["page_title"] = "User Settings for {$auth_row['username']}";
$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a>
 					&gt; <a href=\"{$base_url}/prefs.php\">Account Preferences</a> 
 					&gt; {$auth_row['username']}";

$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();

pika_exit($buffer);
?>
