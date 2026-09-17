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
	// text/txt is not a media type. Nothing registers it, so what a browser
	// does with it is a matter of policy rather than of specification.
	header('Content-Type: text/plain; charset=utf-8');
	header("Content-Disposition: attachment; filename=com.pikasoftware.cms-csv-download.plist");
	echo pl_template('app/scripts/com.pikasoftware.cms-csv-download.plist', $a);
	exit();
}

else if (pl_grab_post('script') == 'Download Script')
{
	/*	The URL written into the generated script is the address that script
		posts this operator's OCM username and password to, from cron, for as
		long as it is installed. It was built out of $_SERVER['HTTP_HOST'],
		which is the Host header of the request: unvalidated, and under
		Apache's default UseCanonicalName Off, whatever was sent.
		
		pl_canonical_origin() is what the rest of the application uses for
		this -- services/twilio.php, the SSO callback, ops/update_activity.php.
		It prefers the canonical_url setting, so a deployment that cannot trust
		the Host header has somewhere to say so, and it holds the host to a
		hostname shape and refuses anything else instead of pasting it in.
		
		It is not a complete answer on a deployment that has not set
		canonical_url: there SERVER_NAME still comes from the Host header, and
		this becomes a shape check rather than a check on the name. That is the
		same position every other caller is in, and the setting is the fix for
		it in all of them.
		
		'https' is passed because this line has always forced https, and the
		script it writes has TLS verification on at both ends; letting the
		scheme follow the request would silently write an http URL, and this
		script sends the operator's password over it from cron.
		
		One thing changes with that. HTTP_HOST carries the port when it is not
		the default one, and pl_canonical_origin() deliberately leaves the port
		off when the scheme is forced -- the port a request arrived on is not
		the forced scheme's port. So a deployment reached on a non-standard
		port used to get "https://host:8080/cms" here and now gets
		"https://host/cms". canonical_url is the setting for that, and it is
		the setting for every other case where the derived origin is not the
		one the outside world uses.
	*/
	$a = array('username' => $auth_row['username'],
				'url' => pl_canonical_origin('https') . pl_settings_get('base_url'),
				'save_folder_path' => pl_grab_post('home_path', '', 'text') . "/cms",
				'password' => pl_grab_post('password', '', 'text'));
	header('Content-Type: text/plain; charset=utf-8');
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
