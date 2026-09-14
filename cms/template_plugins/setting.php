<?php


function setting($field_name = null, $field_value = null, $menu_array = null, $args = null)
{
	$setting_output = '';
	
	/*	The blocklist here named dbhost, dbuser and dbpass. No setting has
		ever carried any of those three labels: the real ones are db_host,
		db_user and db_password. The list blocked nothing, so this plugin
		would hand back the database password, the TOTP encryption key, the
		OIDC client secret or the SMS credentials to any template that asked
		for them by name.
		
		There is one list of settings that must never resolve from a
		template, pl_settings_template_blocked() in app/lib/pl.php, and it is
		kept beside the code that writes those settings. Use it, so a
		credential added later is covered here without anybody remembering to
		come back and edit this file.
	*/
	require_once('pikaSettings.php');
	$settings = pikaSettings::getInstance();
	
	if($settings[$field_name] && !pl_settings_template_blocked($field_name))
	{
		$setting_output = $settings[$field_name];
	}
	
	return $setting_output;
}

?>