<?php

// Libraries
chdir("../");
require_once ('pika-danio.php');

/*	Token based authorization - optional, for calendar clients that cannot do
	HTTP authentication.
	
	The token used to be base64(serialize(array($username, $password_hash))),
	pulled apart with explode('"'), pushed into PHP_AUTH_USER/PHP_AUTH_PW and
	handed to pikaAuthDb. Two things were wrong with that:
	
	  * The subscription URL carried the account's password hash, which ends
	    up in the calendar client's config file on disk, in browser history,
	    and in every proxy log on the way here.
	    
	  * It never worked. pikaAuthDb compares a submitted password against the
	    stored hash, so the hash never matched itself and this file answered
	    401 to the exact URL cms/ical-subscribe.php produced.
	
	It is an opaque token now, checked with hash_equals() against
	users.cal_token. A token that does not verify gets a 401 and nothing else:
	there is no fallback to another credential and no message saying which
	part was wrong. See cms/app/lib/pikaCalToken.php.
*/
if (isset($_GET['token']) && $_GET['token']) {
	define('PL_DISABLE_SECURITY',true);
	pika_init();
	require_once('app/lib/pikaCalToken.php');
	
	$auth_row = pl_cal_token_verify(
		isset($_GET['user_id']) ? $_GET['user_id'] : null,
		$_GET['token']);
	
	if (false === $auth_row) {
		header('HTTP/1.1 401 Unauthorized');
		header('Content-Type: text/plain; charset=utf-8');
		exit("Invalid calendar subscription token.\n");
	}
}
else {
	define('PL_HTTP_SECURITY',true);
	pika_init();
}

require_once ('plFlexList.php');
require_once ('app/lib/plIcalText.php');



// Functions
/*	Kept under its own name because both feeds call it; the escaping itself
	lives in app/lib/plIcalText.php so the two cannot drift apart again.  It
	now also escapes backslash, semicolon and comma per RFC 5545, which the
	local version never did - see pl_ical_text_escape().
*/
function ical_text_mogrify($x)
{
	return pl_ical_text_escape($x);
}

function ical_datetime_mogrify($d, $t)
{
	if (is_null($d) || is_null($t)) 
	{
		return "";
	}
	return date("Ymd", strtotime($d)) . "T" . date("His", strtotime($t));
}
// Variables
$base_url = pl_settings_get('base_url');
$time_zone = pl_settings_get('time_zone');
//$time_zone = 'America/New_York'; // America/New_York, America/Chicago, America/Denver, America/Phoenix, America/Los_Angeles

if(isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] == TRUE) {
	$cal_url= "https://".$_SERVER['HTTP_HOST'].$base_url;
}else { $cal_url= "http://".$_SERVER['HTTP_HOST'].$base_url; }

/*	The HTTP path fills $auth_row through pikaAuthHttp; the token path above
	has already filled it. Re-reading it unconditionally, which is what this
	did, threw the token path's row away and left $user_id empty -- so the
	feed's WHERE user_id='' matched nothing and the subscription came back as
	an empty calendar rather than an error.
*/
require_once('pikaAuth.php');

if (!isset($auth_row) || !is_array($auth_row) || !isset($auth_row['user_id'])) {
	$auth_row = pikaAuthHttp::getInstance()->getAuthRow();
}

$user_id = (int) $auth_row['user_id'];

pl_menu_get('act_type');
pl_menu_get('category');
pl_menu_get('funding');
pl_menu_get('yes_no');

// AMW - 2012-1-24 - Show appointments out through 18 months.
// AMW - 2012-1-25 - Show all future appointments until you hit the record limit.
$current_date = date('U');
// AMW - 2012-1-24 - Show 60 days prior.
$current_date = $current_date - (60*24*60*60);
$current_date = date('Y-m-d',$current_date);

// Main Code
$sql = "SELECT activities.*, cases.number
		FROM activities
		LEFT JOIN cases ON activities.case_id = cases.case_id
		WHERE activities.user_id='{$user_id}'
		AND act_date >= '{$current_date}'
		AND act_type IN ('C', 'K')
		ORDER BY act_date ASC, act_time ASC 
		LIMIT 2000;";

$result = DB::query($sql) or trigger_error(DB::error());
//echo $sql;
$ical_list = new plFlexList();
$ical_list->template_file = "subtemplates/ical/{$time_zone}/ical.txt";
$counter = 0;
while ($row = DBResult::fetchRow($result))
{
	$temp_description = "";
	$row['notes'] = ical_text_mogrify($row['notes']);  //str_replace("\r", "=0D=0A=", stripslashes($row['notes']))
	// Assemble the description field
	if(isset($row['notes']) && $row['notes']) {
		$temp_description .= "Notes: ".$row['notes'] . "\\n\\n";
	}
	if(isset($row['hours'])) {
		$temp_description .= "Hours: " . ($row['hours']+0) . "\\n";
	}
	if(isset($row['completed'])) {
		$temp_description .= "Completed: " . ical_text_mogrify(pl_array_lookup($row['completed'], $plMenus['yes_no'])) . "\\n";
	}
	if(isset($row['act_type']) && $row['act_type']) {
		$temp_description .= "Activity Type: " . ical_text_mogrify(pl_array_lookup($row['act_type'],$plMenus['act_type'])) . "\\n";
	}
	if(isset($row['category']) && $row['category']) {
		$temp_description .= "Category: " . ical_text_mogrify(pl_array_lookup($row['category'], $plMenus['category'])) . "\\n";
	}
	if(isset($row['funding']) && $row['funding']) {
		$temp_description .= "Funding: " . ical_text_mogrify(pl_array_lookup($row['funding'],$plMenus['funding'])) . "\\n";
	}
	if(isset($row['case_id']) && $row['case_id']) {
		$temp_description .= "Case: " . ical_text_mogrify($row['number']) . "\\n";
	}
	$row['cal_url'] = $cal_url . "/activity.php?act_id={$row['act_id']}";
	$temp_description .= $row['cal_url'];
	
	$row['ical_description'] = $temp_description;
	$row['summary'] = ical_text_mogrify($row['summary']);  
	$row['start'] = ical_datetime_mogrify($row['act_date'], $row['act_time']);
	if(!$row['act_end_time']) {
		$row['end'] = $row['start'];
	}else {
		$row['end'] = ical_datetime_mogrify($row['act_date'], $row['act_end_time']);
	}
	$row['time_zone'] = $time_zone;
	/*	$row['summary'] was escaped a few lines up, and the stripslashes() that
		used to be here undid it: the escaped \n became a bare n, so a two-line
		summary reached subscribers as one run-on word.  It did not forge a
		property - the newline was already gone rather than restored - but now
		that the escape set also covers backslash, semicolon and comma it would
		corrupt those too, and this property is semicolon delimited.
	*/
	$row['alarm'] = ical_datetime_mogrify($row['act_date'], $row['act_time']).";P1D;7;TICKLE - " .$row['summary'];
	
	if (!is_null($row['act_date'])) {
		// TODO doesn't work
		//$row['ical_text'] = trim(pl_template('subtemplates/ical.txt', $row,'todo'));
		$row['ical_text'] = trim(pl_template("subtemplates/ical/{$time_zone}/ical.txt", $row, 'calendar'));
		$ical_list->addHtmlRow($row);
		$counter++;
	}
	
}
if($counter == 0) {
	$buffer = trim(pl_template("subtemplates/ical/{$time_zone}/ical.txt",array(),'flex_header') . pl_template("subtemplates/ical/{$time_zone}/ical.txt",array(),'flex_footer'));	
}else {
	$buffer = trim($ical_list->draw());
}

if(!isset($_GET['debug']))
{
	header("Content-Type: text/Calendar");
	header("Content-Disposition: attachment; filename=\"pika.ics\"");
}
exit($buffer);

?>
