<?php

/****************************************/
/* Pika CMS	(C) 2011 Pika Software, LLC	*/
/* http://pikasoftware.com				*/
/****************************************/


// GLOBAL VARIABLES
$auth_row = array();

// CONSTANTS
if(!defined('PIKA_VERSION'))   {  define('PIKA_VERSION', '7');       }
if(!defined('PIKA_REVISION'))  {  define('PIKA_REVISION', '1');     }
if(!defined('PIKA_PATCH_LEVEL'))  {  define('PIKA_PATCH_LEVEL', '1');     }
if(!defined('PIKA_CODE_NAME')) {  define('PIKA_CODE_NAME', 'danio'); }


/**
 * pl_act_row_owner_matches - true when an activity row belongs to this user,
 * with the empty and zero cases excluded.
 *
 * The historical test was a bare ==, which in PHP puts '', 0 and null
 * uncomfortably close together depending on the version and the column type.
 * Compare as strings and refuse to match on an empty owner, so an unowned row
 * is never "owned by whoever is asking".
 *
 * @return boolean
 * @param array $row      activity row
 * @param array $auth_row current user's auth row
*/
function pl_act_row_owner_matches($row, $auth_row)
{
	if (!is_array($row) || !is_array($auth_row))
	{
		return false;
	}
	
	$owner = isset($row['user_id']) ? (string) $row['user_id'] : '';
	$me = isset($auth_row['user_id']) ? (string) $auth_row['user_id'] : '';
	
	if ('' === $owner || '' === $me || '0' === $owner)
	{
		return false;
	}
	
	return $owner === $me;
}


/**
 * pl_act_row_is_pro_bono - true when an activity row is genuinely a pro bono
 * attorney's row, that is: it names a pba and no staff user.
 *
 * This is the question the "no user owns it, so it must be PB" grants in
 * read_act and edit_act were trying to ask. Asking it directly fails closed on
 * the rows that merely have a blank user_id -- imports, rows left behind by a
 * deleted user, rows written by an integration -- instead of exposing them to
 * every authenticated user.
 *
 * @return boolean
 * @param array $row activity row
*/
function pl_act_row_is_pro_bono($row)
{
	if (!is_array($row))
	{
		return false;
	}
	
	$owner = isset($row['user_id']) ? (string) $row['user_id'] : '';
	
	if ('' !== $owner && '0' !== $owner)
	{
		return false;
	}
	
	$pba = isset($row['pba_id']) ? (string) $row['pba_id'] : '';
	
	return '' !== $pba && '0' !== $pba;
}


/**
 * Determine whether the user identified by $row has permission to perform action $op.
 * @return boolean
 * @param string $op
 * @param array $row
*/
function pika_authorize($op, $row)
{
	global $auth_row;
	
	if ('system' == $auth_row['group_id'])
	{
		return true;
	}
	
	$allow_this = false;
	
	switch ($op)
	{
		case 'read_case':
		
		if ($auth_row['read_all'])
		{
			$allow_this = true;
		}
		
		else if ($row['user_id'] == $auth_row['user_id'])
		{
			$allow_this = true;
		}
		
		else if ($row['cocounsel1'] == $auth_row['user_id'])
		{
			$allow_this = true;
		}
		
		else if ($row['cocounsel2'] == $auth_row['user_id'])
		{
			$allow_this = true;
		}
		
		// Intake permission: a group flagged `intake` may read cases that
		// are not fully set up yet -- no primary handler assigned, or no
		// office assigned -- so a new record can be triaged and completed
		// during intake without the person entering it locking themselves
		// out of it.
		//
		// This REPLACES two unconditional grants that used to sit here, one
		// on a null user_id and one on a null office. The comment beside
		// them read "this is handy for intake staff who don't have a default
		// office set", which is a real need, but the grants were not limited
		// to intake staff: they applied to every authenticated user. A user
		// whose group had read_all = 0 and no office in read_office could
		// still read any case with no handler or no office -- and on a legal
		// aid installation those are the new intakes, the most sensitive
		// records in the system. CWE-639.
		//
		// The flag defaults to 0, so this narrows access on upgrade. Grant
		// `intake` to whichever group does intake at your organisation
		// (System > Security Levels).
		else if (!empty($auth_row['intake'])
			&& (is_null($row['user_id']) || is_null($row['office'])))
		{
			$allow_this = true;
		}
		
		// read_office is a comma-separated char(64) in the groups table that
		// pikaAuth::processAuthRow() explodes into an array -- but only when
		// it is a non-empty string. A group with no offices leaves it NULL,
		// and in_array() with a NULL haystack is a TypeError on PHP 8, which
		// this application answers with HTTP 200 and an empty body. Check the
		// shape before using it.
		else if (!empty($auth_row['read_office'])
			&& is_array($auth_row['read_office'])
			&& in_array($row['office'], $auth_row['read_office']))
		{
			$allow_this = true;
		}
		
		break;
		
		
		case 'edit_case':
		
		if ($auth_row['edit_all'])
		{
			$allow_this = true;
		}
		
		else if ($row['user_id'] == $auth_row['user_id'])
		{
			$allow_this = true;
		}
		
		else if ($row['cocounsel1'] == $auth_row['user_id'])
		{
			$allow_this = true;
		}
		
		else if ($row['cocounsel2'] == $auth_row['user_id'])
		{
			$allow_this = true;
		}
		
		// Intake permission -- see the matching branch in 'read_case' above.
		// An intake group gets FULL edit on a case that is not fully set up
		// yet (no handler, or no office) so they can finish the data entry.
		// This replaces the same pair of unconditional any-user grants, which
		// on the write side meant every authenticated user could edit any
		// unassigned case.
		//
		// Note what this does not fix: ops/update_case.php still assigns
		// $_POST onto the case row wholesale, so a user who reaches a case
		// through this branch can set arbitrary case columns on it. That
		// field allowlist is a separate change.
		else if (!empty($auth_row['intake'])
			&& (is_null($row['user_id']) || is_null($row['office'])))
		{
			$allow_this = true;
		}
		
		// Same NULL-haystack guard as read_office above.
		else if (!empty($auth_row['edit_office'])
			&& is_array($auth_row['edit_office'])
			&& in_array($row['office'], $auth_row['edit_office']))
		{
			$allow_this = true;
		}
		
		break;
		
		
		case 'read_act':
		
		if ($auth_row['read_all'])
		{
			$allow_this = true;
		}
		
		else if (pl_act_row_owner_matches($row, $auth_row))
		{
			$allow_this = true;
		}
		
		/*	AMW's grant here was "allow anyone to read a row that no user owns
			(should only be PB)", tested as strlen($row['user_id']) == 0. The
			parenthetical was the intent and the test was not: an activity ends
			up with an empty user_id for several reasons that have nothing to do
			with pro bono work -- an imported row, a row created by a user who
			has since been deleted, a row written by an integration -- and every
			one of those became readable by every authenticated user, whatever
			their office scope and whether or not they could read the case the
			activity hangs off.
			
			Confirmed on this codebase before the fix: a user in a group with
			no read_all, no read_office and no intake was refused
			case.php?case_id=N outright, and still got the full notes of an
			activity on that case by asking for activity.php?act_id=M.
			
			So ask the question the comment was asking -- is this actually a pro
			bono attorney's row? -- which needs a pba_id and no staff user.
		*/
		else if (pl_act_row_is_pro_bono($row))
		{
			$allow_this = true;
		}

		break;
		
		/*	Contact writes.
			
			dataops.php could update a contact record, and add aliases to one,
			with no authorization check at all: the only gate in that file runs
			when the request carries a case_id, and a contact write does not need
			one. A contact row holds the client's name, address, phone, date of
			birth and social security number.
			
			There is no permission column for contacts, so authorize against the
			cases the contact is attached to -- as the primary client, or through
			the conflict table -- and grant if the user may edit at least one of
			them. That matches how the application actually presents contacts:
			they are reached from a case.
		*/
		case 'edit_contact':
		
		if ($auth_row['edit_all'])
		{
			$allow_this = true;
		}
		
		else if (isset($row['contact_id']) && is_numeric($row['contact_id']))
		{
			$sql = "SELECT DISTINCT cases.* FROM cases
				LEFT JOIN conflict ON conflict.case_id = cases.case_id
				WHERE cases.client_id = ? OR conflict.contact_id = ?";
			$result = DB::preparedQuery($sql, array($row['contact_id'], $row['contact_id']));
			$has_any_case = false;
			
			if ($result)
			{
				while ($contact_case_row = DBResult::fetchRow($result))
				{
					$has_any_case = true;
					
					if (pika_authorize('edit_case', $contact_case_row))
					{
						$allow_this = true;
						break;
					}
				}
			}
			
			/*	A contact on no case at all. The walk above has nothing to
				authorize against, so every user without edit_all would land on
				deny and could not edit a record they had just created from
				contact.php. Such a record carries no case's confidentiality,
				and the address book is already readable instance-wide, so
				whoever may create one may edit one.
			*/
			if (!$allow_this && !$has_any_case)
			{
				$allow_this = true;
			}
		}
		
		break;
		
		case 'edit_doc':
		
		if ($auth_row['edit_all'])
		{
			$allow_this = true;
		}
		
		else if ($row['user_id'] == $auth_row['user_id'])
		{
			$allow_this = true;
		}
			
		break;
		
		case 'edit_act':
		
		if ($auth_row['edit_all'] && pl_settings_get('db_name') != 'legalaidnebraska')
		{
			$allow_this = true;
		}
		
		else if (pl_act_row_owner_matches($row, $auth_row))
		{
			$allow_this = true;
		}
		
		// Same correction as read_act above, and it matters more here: an
		// unowned row was editable by any authenticated user, which includes
		// rewriting its notes and re-pointing its hours.
		else if (pl_act_row_is_pro_bono($row))
		{
			$allow_this = true;
		}
		
		break;
		
		case 'users':
		
		if ($auth_row['users'])
		{
			$allow_this = true;
		}
		
		break;
		
		case 'motd':
		
		if ($auth_row['motd'])
		{
			$allow_this = true;
		}
		
		break;

		case 'system':
		case 'delete_case':
		case 'delete_act':
		
		if ('system' == $auth_row['group_id'])
		{
			$allow_this = true;
		}
		
		break;
	}
	
	return $allow_this;
}


/**
 * Implements security on Pika reports
 * @param string $report_name - name of report requested
 * @return boolean (true/false) - true if authorized - false if otherwise
*/
function pika_report_authorize($report_name)
{ 
	
	global $auth_row;
	$allow_this = false;
	
	if ('system' == $auth_row['group_id'])
	{
		return true;
	}
	
	
	$reports = array();
	if(strlen($auth_row['reports']) > 1) {
		if(strpos($auth_row['reports'],',') !== false) {
			$reports = explode(',',$auth_row['reports']);
		} else {
			$reports[] = $auth_row['reports'];
		}
	}
	foreach ($reports as $report) {
		if($report_name == $report) { $allow_this = true; }
	}
	
	return $allow_this;
}

/**
 * Performs shutdown tasks for "danio" scripts.
 * This function should be called at the end of every "danio"-based 
 * script.
 *
 * @return boolean
*/
function pika_exit($buffer)
{
	// FONT SIZE
	/* H4 for backward compat. */
	/*
	$pikaFontSizes = array();
	$pikaFontSizes['Small'] = "
	BODY { font-size: 13px; }\n
	TR { font-size: 12px; }\n
	INPUT, SELECT, TEXTAREA, TH, .row1, .row2 { font-size: 11px; }\n
	TT { font-size: 14px; }\n
	.mycal, .othercal { font-size: 10px; }\n
	H1 { font-size: 18px; }\n
	H1.crumbtrail { font-size: 13px; }\n
	H2, H4 { font-size: 15px;	}\n
	.small { font-size: 10px; }\n
	.nav, .nav a { font-size: 11px; }
	";
	$pikaFontSizes['Medium'] = '';
	*/
	/* BODY 15px
	// H1 20px;
	// h1.crumbtrail 14px;
	// H2 17px
	// TR 13px
	// TH 12px
	// TT ?
	// .small ?
	// ,mycal, .othercal ?
	*/
	/*
	$pikaFontSizes['Large'] = "
	BODY { font-size: 16px; }\n
	TR { font-size: 14px; }\n
	INPUT, SELECT, TEXTAREA, TH, .row1, .row2 { font-size: 13px; }\n
	TT { font-size: 16px; }\n
	.mycal, .othercal { font-size: 12px; }\n
	H1 { font-size: 21px; }\n
	H1.crumbtrail { font-size: 15px; }\n
	H2, H4 { font-size: 18px;	}\n
	.small { font-size: 12px; }\n
	.nav, .nav a { font-size: 13px; }
	";
	$pikaFontSizes['Super Size'] = "
	BODY { font-size: 18px; }\n
	TR { font-size: 16px; }\n
	INPUT, SELECT, TEXTAREA, TH, .row1, .row2 { font-size: 15px; }\n
	TT { font-size: 17px; }\n
	.mycal, .othercal { font-size: 13px; }\n
	H1 { font-size: 22px; }\n
	H1.crumbtrail { font-size: 46px; }\n
	H2, H4 { font-size: 19px;	}\n
	.small { font-size: 13px; }\n
	.nav, .nav a { font-size: 14px; }
	";
	*/

	// Color Schemes - the 4px line at the bottom of the header.
	/*
	2013-08-14 AMW - I turned off Color Schemes, they seem antiquated.  We will see what feedback I get.
	$theme = 'Blue';
	
	if(isset($_SESSION['theme']) && strlen($_SESSION['theme']))
	{
		$theme = $_SESSION['theme'];
	}
	*/
	
	//  2013-08-13 AMW - I removed font size settings; the browsers handle this so much better nowadays.
	/*
	$font_size = 'Medium';
	if(isset($_SESSION['font_size']) && strlen($_SESSION['font_size']))
	{
		$font_size = $_SESSION['font_size'];
	}

	$pikaTheme = str_replace("url(", "url({$base_url}/", $pikaTheme);
	*/
	// Include theme, font size CSS code in the HTML header
	//$plTemplate['header'] = "-->\n<style type='text/css'><!--\n{$pikaTheme}\n{$pikaFontSizes[$font_size]}\n--></style>\n<!--";
	//$theme_css_str = "<style type='text/css'><!--\n{$pikaTheme}\n{$pikaFontSizes[$font_size]}\n--></style>";
	
	/*
	2013-08-14 AMW - I turned off Color Schemes, they seem antiquated.  We will see what feedback I get.
	$color_schemes = pl_menu_get('color_scheme');
	$theme_css_str = array_search($theme, $color_schemes);
	
	if("" == $theme_css_str) // Something didn't work, use the fallback value.
	{
		$theme_css_str = "#0000DD";
	}
	*/
	
	require_once('app/lib/pikaAuth.php');
	$auth_row = pikaAuth::getInstance()->getAuthRow();
	
	$username = '';
	if(isset($auth_row['username']) && strlen($auth_row['username']) > 0)
	{
		$username = $auth_row['username'];
	}
	
	// 2013-08-14 AMW - I turned off Color Schemes, they seem antiquated.  We will see what feedback I get.
	//$buffer = str_replace("/* color_scheme_value */", $theme_css_str, $buffer);
	$buffer = str_replace("<!-- username -->", pl_clean_html($username), $buffer);
	$buffer = str_replace("<!-- org_name -->", pl_settings_get('owner_name'), $buffer);
	
	//mysql_close();  Don't do this; it will mess up plBase autosaving.
	
	// BENCHMARKING
	if (pl_settings_get('enable_benchmark')) 
	{
		$buffer .= "<p>\n";
		$buffer .= "File Size:  " . round(strlen($buffer) / 1024) . "KB<br/>\n";
		$buffer .= "Server Time:  " . pl_benchmark() . " seconds<br/>\n";
		// Transmit current buffer.
		echo $buffer;
		// Reset buffer, so the page isn't sent twice.
		$buffer = "";
		// Run pl_benchmark() again to see how long the buffer transmit took.
		$buffer .= "Transmit Time:  " . pl_benchmark() . " seconds *<br/>\n";
		$buffer .= "</p>\n";
	}

	// HTML VALIDATION
	// 2013-08-08 AMW - Validation removed due to lack of HTML5 support in tidy application.
	
	echo $buffer;
	exit();
}


/**
 * Returns 9 if the database stores all 9 digits and two hyphens in SSN columns.
 * Returns 4 if only truncated SSNs are stored.
 * Returns 0 if SSNs are not stored.
 *
 * @return boolean
*/
function pika_ssn_mode()
{
	$result = DB::query("DESCRIBE contacts") or trigger_error(DB::error());
	
	while ($row = DBResult::fetchRow($result))
	{
		if ($row['Field'] == 'ssn')
		{
			if ($row['Type'] == 'varchar(11)')
			{
				return 9;
			}
			
			else if ($row['Type'] == 'char(4)')
			{
				return 4;
			}
			
			else if ($row['Type'] == 'char(0)')
			{
				return 0;
			}
			
			else 
			{
				return null;
			}
		}
	}
}


/**
 * Initializes the Pika CMS "danio" framework.
 * This function should be called at the beginning of every "danio"-based 
 * script.  If the user is not authenticated, it will display the login
 * screen and exit, so the remainder of the script cannot be accessed.
 *
 * @return boolean
*/
function pika_init()
{
	global $auth_row;
	/* 2013-08-14 AMW - Copying old code into the Extensions folder often
	ends up with pika_init() getting called twice.  To make things simple
	to migrate code to Extensions, keep track of how many times pika_init
	gets called, and only let it run once. */
	static $z = 0;
	$z++;
	
	if ($z > 1)
	{
		return true;
	}
	
	/* Play some games with the PHP include_path so the 'gila'
	framework libraries are not available.
	*/
	$include_str = './app/lib' . PATH_SEPARATOR . './app/extralib' 
		. PATH_SEPARATOR . ini_get('include_path');
	ini_set('include_path', $include_str);
	
	// Now that the include_path is set, load the danio pl.php library.
	//TODO fix this
	require_once('pl.php');
	
	// Before we go any further, start the benchmark timer.
	pl_benchmark();
	// Notify PHP to use the custom Pika error handler.
	set_error_handler("pl_error_handler");
	
	/* Override the default PHP session handler.*/
	session_set_save_handler("pl_session_open", "pl_session_close", "pl_session_read", "pl_session_write","pl_session_destroy", "pl_session_gc");

	
	// destroy all MAGIC QUOTES
	if (PHP_VERSION_ID < 80000)
	{
	  if (get_magic_quotes_runtime() == true)
	  {
		set_magic_quotes_runtime(false);
	  }
	}
	
	/* The default pl_template tag prefix and suffix are '[[' and ']]',
	change this.
	*/
	define('PL_TEMPLATE_PREFIX', '%%[');
	define('PL_TEMPLATE_SUFFIX', ']%%');
	
	/* Set location of settings file */
	define('PL_SETTINGS_FILE', pl_custom_directory() . '/config/settings.php');
	define('PL_DEFAULT_PREFS_FILE', pl_custom_directory() . '/config/default_prefs.php');
	
	// Initialize the connection to the MySQL server.
	if(!defined('PL_DISABLE_MYSQL'))
	{
		pl_mysql_init() or trigger_error('Could not connect to MySQL server.  Please check PikaCMS database connection settings and/or verify that an instance of MySQL is running on the specified host.  ERROR # ' . mysql_errno());
	}
	
	
	ini_set('session.use_cookies', 1);
	ini_set('session.use_only_cookies',1);
	ini_set('session.use_trans_sid', 0);
	ini_set('session.hash_function', 1);
	ini_set('session.hash_bits_per_character', 5);

	require_once('pikaSettings.php');
	$plSettings = pikaSettings::getInstance();
	
	// AMW - This will redirect the user to https:// if they connect over
	// http:// to a server that requires a secure connection.
	//
	// Three fixes here:
	//  - $_SERVER['HTTPS'] was read unguarded. It is absent, not empty, on a
	//    plain-HTTP request, so this emitted an undefined-index notice on the
	//    one path it exists to handle.
	//  - The redirect target came from $_SERVER['SERVER_NAME'], which Apache
	//    fills from the request's Host header unless UseCanonicalName is on.
	//    An attacker who chose the Host header chose where the browser went
	//    next. pl_canonical_origin() prefers the configured canonical_url and
	//    validates the fallback.
	//  - There was no exit() after the header, so the redirect was sent and
	//    then the page was built and served anyway over the insecure
	//    connection that force_https exists to prevent.
	$https_on = isset($_SERVER['HTTPS'])
		&& strlen((string) $_SERVER['HTTPS']) > 0
		&& 'off' !== strtolower((string) $_SERVER['HTTPS']);
	
	if (true == $plSettings['force_https'] && !$https_on)
	{
		$force_https_origin = pl_canonical_origin('https');
		
		if ('' !== $force_https_origin)
		{
			header('Location: ' . $force_https_origin
				. (isset($_SERVER['REQUEST_URI']) ? (string) $_SERVER['REQUEST_URI'] : '/'));
			exit();
		}
	}
	
	// GZIP compression
	if ($plSettings['enable_compression'] && !defined('PIKA_NO_COMPRESSION'))
	{
		ob_start("ob_gzhandler");
	}
	
	
	/*	Mark the session cookie Secure when the request arrived over HTTPS, so
		the browser will not send it again over plain HTTP. This cannot be set
		unconditionally in php.ini: a plain-HTTP install -- `docker compose up`
		on a laptop, or a box behind a proxy that does not forward the scheme --
		cannot log in at all if the cookie is marked Secure, because the browser
		declines to send it back.
	
		The httponly and samesite values also come from php.ini. Passing them
		here again is harmless and makes them true regardless of which ini file
		the deployment ended up with. The legacy argument list has no samesite
		slot; the ini value survives this call (verified on PHP 8.2).
	*/
	session_set_cookie_params(0, $plSettings['base_url'], '', $https_on, true);
	
	 // Set this to avoid other php websites (such as SugarCRM) from invading the current session w/ serialized objects
	$session_name = 'PikaCMS' . PIKA_VERSION . PIKA_REVISION . PIKA_PATCH_LEVEL;
	if(isset($plSettings['cookie_prefix']) && strlen($plSettings['cookie_prefix']))
	{ // Session Name only accepts letters and numbers so remove all non letters and/or numbers
		$session_name = preg_replace('/[^a-z0-9]/i','',$plSettings['cookie_prefix']);
	}
	
	session_name($session_name);
	session_start();
	
	// Set server time zone, per PHP best practices.
	// AMW - 2013-02-20 - I moved this up, above authentication, because authentication
	// was using date() and causing warnings.
	$time_zone = pl_settings_get('time_zone');
	
	if (function_exists('date_default_timezone_set')) 
	{
		if (!$time_zone)
		{
			$time_zone='America/New_York';
		}
		
		date_default_timezone_set($time_zone);
	}
	
	require_once('pikaAuth.php');
	
	// TODO - need to fix pikaAuth to be parent super-object over pikaAuthHttp
	//        until then will need to refer to auth object in context 
	//        pikaAuthHttp in HTTP sections pikaAuth in all other sections
	if(defined('PL_DISABLE_SECURITY'))
	{
		$auth_row = pikaAuth::getInstance()->getAuthRow();
	}
	elseif(defined('PL_HTTP_SECURITY')) 
	{
		authenticate_http();
		$auth_row = pikaAuthHttp::getInstance()->getAuthRow();
	}
	else
	{
		authenticate();
		$auth_row = pikaAuth::getInstance()->getAuthRow();
	}

	/*	MFA enrollment gate. An account whose administrator turned MFA on but
		which has no usable secret yet goes to enroll_mfa.php and nowhere
		else, until it has one. Fails open on any error -- see
		cms/app/lib/pikaMfaEnroll.php.
	*/
	require_once('app/lib/pikaMfaEnroll.php');
	pl_mfa_enroll_gate();
	
	/*	Forced password change. An account whose password was set by somebody
		else -- the container entrypoint on first run, or an administrator on
		the user form -- goes to password.php and nowhere else until the
		account holder has picked their own. Fails open on any error -- see
		cms/app/lib/pikaPasswordChange.php.
		
		After the enrollment gate, so a user who owes both finishes
		enrollment first and is not bounced between the two pages.
	*/
	require_once('app/lib/pikaPasswordChange.php');
	pl_password_change_gate();
	
	require_once('pikaDefPrefs.php');
	pikaDefPrefs::getInstance()->initPrefs($auth_row['user_id']);
	
	return true;
}


?>
