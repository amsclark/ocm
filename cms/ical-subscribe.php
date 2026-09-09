<?php 

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('pika-danio.php');

pika_init();

// This page performs its state changes on a GET: the action is dispatched
// out of the query string and the links that trigger it are plain <a href>
// markup, so a hidden token field is not available as a defence here.
// On a non-POST request pl_csrf_check() falls through to the same-site
// check, which refuses a mutation that a foreign page initiated and needs
// nothing from the markup. See pl_request_cross_site_verdict() in pl.php.
pl_csrf_check();

require_once('pikaUser.php');
require_once('pikaSettings.php');
require_once('pikaTempLib.php');

$main_html = $html = array();
$base_url = pl_settings_get('base_url');

$auth_row = pikaAuth::getInstance()->getAuthRow();
$user = new pikaUser($auth_row['user_id']);

// Generate ICal URL

$ical_url = $ical_token_url = '';
if(isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] == TRUE) {
	$ical_token_url = "http://".$_SERVER['HTTP_HOST'].$base_url;
	$ical_url = "https://".$_SERVER['HTTP_HOST'].$base_url;
}else { $ical_token_url = $ical_url= "http://".$_SERVER['HTTP_HOST'].$base_url; }

$auth_array = array($user->username,$user->password);
$auth_string = serialize($auth_array);
$b64_auth = base64_encode($auth_string);

$html['ical_direct_link'] = $ical_url . "/services/calendar.php";
$html['ical_token_link'] = $ical_token_url . "/services/calendar.php?token={$b64_auth}";

$main_html['page_title'] = 'iCal Subscription';
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> 
					&gt; <a href=\"{$base_url}/cal_day.php\">Calendar</a> 
					&gt; {$main_html['page_title']}";
$template = new pikaTempLib('subtemplates/ical-subscribe.html', $html);
$main_html['content'] = $template->draw();


$default_template = new pikaTempLib('templates/default.html', $main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
