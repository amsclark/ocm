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
		
		else if (!empty($auth_row['intake'])
			&& (is_null($row['user_id']) || is_null($row['office'])))
		{
			$allow_this = true;
		}
		
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
		
		else if (!empty($auth_row['intake'])
			&& (is_null($row['user_id']) || is_null($row['office'])))
		{
			$allow_this = true;
		}
		
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
		
		else if (pl_act_row_is_pro_bono($row))
		{
			$allow_this = true;
		}

		break;
		
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
	
	require_once('app/lib/pikaAuth.php');
	$auth_row = pikaAuth::getInstance()->getAuthRow();
	
	$username = '';
	if(isset($auth_row['username']) && strlen($auth_row['username']) > 0)
	{
		$username = $auth_row['username'];
	}
	
	$buffer = str_replace("<!-- username -->", pl_clean_html($username), $buffer);
	$buffer = str_replace("<!-- org_name -->", pl_settings_get('owner_name'), $buffer);
	
	if (pl_settings_get('enable_benchmark')) 
	{
		$buffer .= "<p>\n";
		$buffer .= "File Size:  " . round(strlen($buffer) / 1024) . "KB<br/>\n";
		$buffer .= "Server Time:  " . pl_benchmark() . " seconds<br/>\n";
		echo $buffer;
		$buffer = "";
		$buffer .= "Transmit Time:  " . pl_benchmark() . " seconds *<br/>\n";
		$buffer .= "</p>\n";
	}

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
	static $z = 0;
	$z++;
	
	if ($z > 1)
	{
		return true;
	}
	
	$include_str = './app/lib' . PATH_SEPARATOR . './app/extralib' 
		. PATH_SEPARATOR . ini_get('include_path');
	ini_set('include_path', $include_str);
	
	require_once('pl.php');
	
	pl_benchmark();
	set_error_handler("pl_error_handler");
	
	session_set_save_handler("pl_session_open", "pl_session_close", "pl_session_read", "pl_session_write","pl_session_destroy", "pl_session_gc");

	
	if (PHP_VERSION_ID < 80000)
	{
	  if (get_magic_quotes_runtime() == true)
	  {
		set_magic_quotes_runtime(false);
	  }
	}
	
	define('PL_TEMPLATE_PREFIX', '%%[');
	define('PL_TEMPLATE_SUFFIX', ']%%');
	
	define('PL_SETTINGS_FILE', pl_custom_directory() . '/config/settings.php');
	define('PL_DEFAULT_PREFS_FILE', pl_custom_directory() . '/config/default_prefs.php');
	
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
	
	if ($plSettings['enable_compression'] && !defined('PIKA_NO_COMPRESSION'))
	{
		ob_start("ob_gzhandler");
	}
	
	session_set_cookie_params(0, $plSettings['base_url'], '', $https_on, true);
	
	 $session_name = 'PikaCMS' . PIKA_VERSION . PIKA_REVISION . PIKA_PATCH_LEVEL;
	if(isset($plSettings['cookie_prefix']) && strlen($plSettings['cookie_prefix']))
	{ 
		$session_name = preg_replace('/[^a-z0-9]/i','',$plSettings['cookie_prefix']);
	}
	
	session_name($session_name);
	session_start();
	
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

	require_once('app/lib/pikaMfaEnroll.php');
	pl_mfa_enroll_gate();
	
	require_once('pikaDefPrefs.php');
	pikaDefPrefs::getInstance()->initPrefs($auth_row['user_id']);
	
	return true;
}


?>