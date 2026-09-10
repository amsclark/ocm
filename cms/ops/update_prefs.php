<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

chdir('../');

require_once ('pika-danio.php');
pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

require_once ('pikaUser.php');
require_once ('pikaDefPrefs.php');



$base_url = pl_settings_get('base_url');

$user_id = $auth_row['user_id'];
$user = new pikaUser($user_id);


/*	Each of these is read back out of the session later on: the theme names
	a file cms/pika_cms.php includes, the paging count is interpolated into
	a LIMIT clause, and the font size is used as an array key. A name that
	the system defaults file does not carry is not overwritten by
	pikaDefPrefs::initPrefs() on the next request, so a bad value stored
	here stays for the rest of the session. Keep the value that is already
	in the session when the request offers one the preference may not hold.
*/
$pref_names = array('def_office',
					'def_intake_type',
					'def_relation_code',
					'paging',
					'font_size',
					'popup',
					'theme',
					'def_ical_interval',
					'def_rss_interval',
					'r_format');

foreach ($pref_names as $pref_name)
{
	$pref_value = pikaDefPrefs::filterValue($pref_name, pl_grab_post($pref_name));
	
	if (!is_null($pref_value))
	{
		$_SESSION[$pref_name] = $pref_value;
	}
}

session_write_close();




header("Location: {$base_url}/prefs.php");


?>