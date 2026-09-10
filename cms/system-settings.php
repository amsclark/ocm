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
	'open_outcomes', 'multi_outcomes', 'ca_iolta_outcomes',
	/*	Single sign-on. sso_client_secret is deliberately NOT in this list:
		it is handled on its own below so that a blank field leaves the
		stored secret alone. sso_allow_insecure_transport is not here either
		and has no field on this form -- it exists for a test harness and is
		set by direct SQL only.
	*/
	'sso_enabled', 'sso_provider', 'sso_tenant_id', 'sso_hosted_domain',
	'sso_issuer_url', 'sso_discovery_url', 'sso_client_id',
	'sso_autobind_by_email', 'sso_autobind_domains',
	/*	Peer case transfer. peer_transfer_shared_secret is deliberately NOT in
		this list, for the same reason as the SSO client secret: it is handled
		on its own below so that a blank field keeps the stored value.
	*/
	'peer_transfer_allow_legacy_unserialize');

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
		
		/*	The client secret is write-only from this form. The field is
			rendered empty, so an administrator who saves the page without
			retyping it must not thereby erase it -- pl_settings_save() is a
			DELETE-all followed by a re-INSERT of the whole merged array, so
			a value that is not set is a value that is gone.
			
			Clearing it on purpose is done by turning SSO off, or with direct
			SQL. A form that can blank a credential by being submitted is a
			form that blanks credentials by accident.
		*/
		if (isset($_POST['sso_client_secret']))
		{
			$posted_secret = (string) $_POST['sso_client_secret'];
			
			if ('' !== $posted_secret)
			{
				$old_secret = (string) pl_settings_get('sso_client_secret');
				pl_settings_set('sso_client_secret', $posted_secret);
				
				if ($old_secret !== $posted_secret)
				{
					$changed['sso_client_secret'] = array('redacted' => true);
				}
			}
		}
		
		/*	Write-only, on the same reasoning as the client secret above.
			Clearing it deliberately is done with direct SQL.
		*/
		if (isset($_POST['peer_transfer_shared_secret']))
		{
			$posted_secret = (string) $_POST['peer_transfer_shared_secret'];
			
			if ('' !== $posted_secret)
			{
				$old_secret = (string) pl_settings_get('peer_transfer_shared_secret');
				pl_settings_set('peer_transfer_shared_secret', $posted_secret);
				
				if ($old_secret !== $posted_secret)
				{
					$changed['peer_transfer_shared_secret'] = array('redacted' => true);
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
		
		/*	Same rule for the OIDC client secret: the browser is told whether
			one is stored, never what it is.
		*/
		$sso_secret_stored = (strlen((string) pl_settings_get('sso_client_secret')) > 0);
		$html['sso_client_secret'] = '';
		$html['sso_secret_status'] = $sso_secret_stored
			? 'A client secret is stored. Leave this blank to keep it.'
			: 'No client secret is stored yet.';
		
		/*	The exact string to register at the identity provider. Providers
			compare the redirect URI byte for byte, and a mismatch is the
			single most common reason a first SSO setup does not work, so the
			value this application will actually send is shown here rather
			than described in prose.
		*/
		require_once('app/lib/pikaSsoOidc.php');
		$html['sso_redirect_uri'] = pl_sso_redirect_uri();
		
		/*	And the peer transfer shared secret. Anybody holding it can sign a
			case of their choosing into this installation, so the browser is
			told whether one is stored and nothing more.
		*/
		$html['peer_transfer_shared_secret'] = '';
		$html['peer_transfer_secret_status'] = (strlen((string) pl_settings_get('peer_transfer_shared_secret')) > 0)
			? 'A shared secret is stored. Leave this blank to keep it.'
			: 'No shared secret is stored. Incoming transfers are refused until one is set.';
		
		$sso_ready_reason = '';
		
		if (!pl_sso_schema_ready())
		{
			$html['sso_status'] = 'The database is missing the single sign-on columns. '
				. 'Apply cms/app/sql/upgrades/add_sso.sql, or restart the container, '
				. 'before turning this on.';
		}
		
		elseif (pl_sso_ready(null, $sso_ready_reason))
		{
			$html['sso_status'] = 'Single sign-on is configured and the sign-in page '
				. 'offers it.';
		}
		
		else
		{
			$html['sso_status'] = 'Single sign-on is not in use. Reason: '
				. $sso_ready_reason;
		}
		
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
		$template->addMenu('sso_provider', array(
			''        => 'None',
			'google'  => 'Google Workspace',
			'entra'   => 'Microsoft Entra ID',
			'generic' => 'Other OpenID Connect provider'
		));
		$main_html['content'] = $template->draw();
		
		break;
}


$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>