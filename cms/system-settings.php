<?php

/**********************************/
/* Pika CMS (C) 2010			  */
/* http://pikasoftware.com		  */
/**********************************/

require_once('pika-danio.php');
pika_init();
require_once('pikaSettings.php');
require_once('pikaMisc.php');
require_once('pikaTempLib.php');

$main_html = $html = array();
$base_url = pl_settings_get('base_url');

$main_html['page_title'] = $page_title = "System Settings";
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

$tzs = array('-7' => '7 Hours Behind',
			'-6' => '6 Hours Behind',
			'-5' => '5 Hours Behind',
			'-4' => '4 Hours Behind',
			'-3' => '3 Hours Behind',
			'-2' => '2 Hours Behind',
			'-1' => '1 Hour Behind',
			'0' => 'Use Server\'s Time Zone',
			'1' => '1 Hour Ahead',
			'2' => '2 Hours Ahead',
			'3' => '3 Hours Ahead',
			'4' => '4 Hours Ahead',
			'5' => '5 Hours Ahead'
			);

$tzs_new = array('America/New_York' => 'America/New_York (EST)',
				'America/Chicago' => 'America/Chicago (CST)',
				'America/Denver' => 'America/Denver (MST)',
				'America/Phoenix' => 'America/Phoenix',
				'America/Los_Angeles' => 'America/Los_Angeles (PST)',
				'America/Anchorage' => 'America/Anchorage (AKST)',
				'Pacific/Honolulu' => 'Pacific/Honolulu (HST)',
				'Pacific/Pago_Pago' => 'Pacific/Pago_Pago'
				);

$pass_max_age = array('0' => 'Never',
				'60' => '60 days',
				'90' => '90 days',
				'120' => '120 days',
				'365' => '365 days');


$pass_min_strength = array(	'0' => 'None',
							'2' => 'Light',
							'3' => 'Moderate',
							'4' => 'Strong');
					
$pass_min_length = array('0' => 'None',
						'2' => '2 or More',
						'3' => '3 or More',
						'4' => '4 or More',
						'5' => '5 or More',
						'6' => '6 or More',
						'7' => '7 or More',
						'8' => '8 or More',
						'9' => '9 or More',
						'10' => '10 or More');
						
// AMW - These are the password expiration options.
$expire = array('0' => "Unlimited",
				'60' => "60 days",
				'90' => "90 days",
				'120' => "120 days",
				'365' => "365 days");

// AMW - This array is the list of settings to pull out of $_POST when doing
// a save operation.  If you add a new field to the system setting screen,
// add the field name to this array list, and you won't need to manually add
// an array element when upgrading an existing Pika install.  Just have the
// local admins check the screen and hit Save to confirm the new field and
// it's value.
// 2013-08-08 AMW - Removed 'enable_html_tidy' because tidy validation is deprecated.
// 2013-08-23 AMW - Removed 'base_url' and 'base_directory' because they need to move
// back to the (read only) settings.php file so multiple sites can run off one DB.
$list_of_settings = array('cookie_prefix', 'enable_system', 'enable_compression',
	'enable_benchmark', 'autonumber_on_new_case',
	'owner_name', 'admin_email', 'act_interval',
	'time_zone', 'time_zone_offset', 'session_timeout', 'pass_min_strength',
	'pass_min_length', 'password_expire', 'force_https', 'autofill_time_funding',
	'open_outcomes', 'multi_outcomes', 'ca_iolta_outcomes');

switch ($action)
{
	case 'update':
		// Track which settings actually changed so the audit log records a
		// usable diff rather than every key in the form.
		$changed = array();
		foreach ($list_of_settings as $setting_name)
		{
			if(isset($_POST[$setting_name]))
			{
				if ('session_timeout' == $setting_name)
				{
					//  AMW
					// Users enter the session timeout in minutes.  Convert this
					// to seconds for use by Pika.
					$new_value = $_POST['session_timeout'] * 60;
					$old_value = pl_settings_get('session_timeout');
					pl_settings_set('session_timeout', $new_value);
				}
				
				else
				{
					$new_value = $_POST[$setting_name];
					$old_value = pl_settings_get($setting_name);
					pl_settings_set($setting_name, $new_value);
				}
				
				if ((string)$old_value !== (string)$new_value)
				{
					// Never log a password-like setting value; just record
					// that it changed. Keeps secrets out of audit records
					// even when they live in the settings table.
					$is_secret = (stripos($setting_name, 'password') !== false
					           || stripos($setting_name, 'secret')   !== false
					           || stripos($setting_name, 'api_key')  !== false
					           || stripos($setting_name, 'auth_token') !== false);
					$changed[$setting_name] = $is_secret
						? array('redacted' => true)
						: array('old' => $old_value, 'new' => $new_value);
				}
			}
		}
		
		pl_settings_save();
		
		if (!empty($changed))
		{
			pl_audit('setting.update', 'setting', null, array('changed' => $changed));
		}
		
	default:

		$html = pl_settings_get_all();
		
		// AMW - do not transmit the database password, that field stays blank.
		$html['db_password'] = '';
		
		// AMW - convert session timeout limit from seconds (internal)to 
		// minutes (user-space).
		$html['session_timeout'] = $html['session_timeout'] / 60;
		
		$template = new pikaTempLib('subtemplates/system-settings.html',$html);
		$template->addMenu('time_zone',$tzs_new);
		$template->addMenu('time_zone_offset',$tzs);
		$template->addMenu('pass_max_age',$pass_max_age);
		$template->addMenu('pass_min_strength',$pass_min_strength);
		$template->addMenu('pass_min_length',$pass_min_length);
		$template->addMenu('password_expire', $expire);
		$main_html['content'] = $template->draw();
		
		break;
}


$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>