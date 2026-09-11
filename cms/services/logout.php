<?php

chdir('..');

define('PL_DISABLE_SECURITY',true);

include('pika-danio.php');
pika_init();
require_once('pikaAuth.php');
require_once('pikaSettings.php');
require_once('app/lib/pikaSsoOidc.php');

/*	Who is signing out has to be read before logout(), which marks the
	session row and makes it unreadable. Only accounts that authenticate
	through single sign-on are ever sent on to the identity provider.
*/
$signing_out = pl_sso_session_user();

pikaAuth::getInstance()->logout();


$settings = pikaSettings::getInstance();

if (is_array($signing_out) && isset($signing_out['auth_method'])
	&& 'sso' === (string) $signing_out['auth_method'])
{
	$sso_logout_url = pl_sso_end_session_url();
	
	if ('' !== $sso_logout_url)
	{
		pl_audit('sso.logout.redirect', 'user', (int) $signing_out['user_id'],
			array('provider' => (string) pl_settings_get('sso_provider')),
			(int) $signing_out['user_id'], $signing_out['username']);
		
		header('Location: ' . $sso_logout_url);
		exit();
	}
}

header("Location: " . $settings['base_url']);
