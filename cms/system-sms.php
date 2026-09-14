<?php

/**********************************/
/* Pika CMS (C) 2010			  */
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
require_once('pikaSettings.php');
require_once('pikaMisc.php');
require_once('pikaTempLib.php');

$main_html = $html = array();
$base_url = pl_settings_get('base_url');

$main_html['page_title'] = $page_title = "SMS Settings";
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; 
						<a href=\"{$base_url}/site_map.php\">Site Map</a> &gt; 
						{$page_title}";

$action = pl_grab_post('action');

if (!pika_authorize('system',array()))
{
	$main_html['content'] = "Access denied";
	
	$default_template = new pikaTempLib('templates/default.html',$main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}

switch ($action)
{
	case 'update':

		pl_settings_set('twilio_account_sid', pl_grab_post('twilio_account_sid'));
		pl_settings_set('twilio_number', pl_grab_post('twilio_number'));
		pl_settings_set('sparkpost_from_address', pl_grab_post('sparkpost_from_address'));
		
		/*	The Twilio authentication token and the SparkPost API key are
			write-only from this form, on the same rule as the OIDC client
			secret and the peer transfer shared secret in system-settings.php.
			
			The field is rendered empty, so an administrator who saves this
			page without retyping the credential must not thereby erase it:
			pl_settings_save() is a DELETE-all followed by a re-INSERT of the
			whole merged array, so a value that is not set is a value that is
			gone. Clearing one on purpose is done with direct SQL.
		*/
		foreach (array('twilio_auth_token', 'sparkpost_api_key') as $sms_secret)
		{
			if (isset($_POST[$sms_secret]))
			{
				$posted_secret = (string) $_POST[$sms_secret];
				
				if ('' !== $posted_secret)
				{
					pl_settings_set($sms_secret, $posted_secret);
				}
			}
		}
		
		pl_settings_save();
		
	default:

		$html['twilio_account_sid'] = pl_settings_get('twilio_account_sid');
		$html['twilio_number'] = pl_settings_get('twilio_number');
		$html['sparkpost_from_address'] = pl_settings_get('sparkpost_from_address');
		
		/*	Both credentials were read back out of the settings table and
			rendered into the value attribute of a plain text input, so the
			page handed the live Twilio token and the live SparkPost key to
			anybody who could reach it -- and to anything that could read the
			response: a browser extension, a cached page, a screenshot, a
			proxy log. Send whether one is stored, never what it is.
		*/
		$html['twilio_auth_token'] = '';
		$html['twilio_auth_token_status'] = (strlen((string) pl_settings_get('twilio_auth_token')) > 0)
			? 'A token is stored. Leave this blank to keep it.'
			: 'No token is stored yet.';
		
		$html['sparkpost_api_key'] = '';
		$html['sparkpost_api_key_status'] = (strlen((string) pl_settings_get('sparkpost_api_key')) > 0)
			? 'An API key is stored. Leave this blank to keep it.'
			: 'No API key is stored yet.';
		
		$template = new pikaTempLib('subtemplates/system-sms.html',$html);
		$main_html['content'] = $template->draw();
		
		break;
}


$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>