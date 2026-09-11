<?php

/*	AMW 2018-12-24 This is the iCal service for organizations still running v.4
 		or lower, the original file in v.4 had an issue related to the function
		unserialize, and this version contains the fix.
		*/ 

/*	Token based authorization - optional, for calendar clients that cannot do
	HTTP authentication.
	
	What used to be here decoded base64(serialize(array($username,
	$password_hash))) and wrote the two halves into PHP_AUTH_USER and
	PHP_AUTH_PW -- and then never called an authenticator. pika_init() below
	runs with no security constant, so this file was session authenticated and
	the whole token block did nothing at all: a calendar client hitting it with
	a token got the login page, not a feed.
	
	It verifies the token now, the same way cms/services/calendar.php does, and
	answers 401 when it does not check out. See cms/app/lib/pikaCalToken.php.
*/
$pl_cal_use_token = isset($_GET['token']) && $_GET['token'];

// Libraries
chdir("../");

if ($pl_cal_use_token) {
	define('PL_DISABLE_SECURITY',true);
}

require_once ('pika-danio.php');
pika_init();

if ($pl_cal_use_token) {
	require_once ('app/lib/pikaCalToken.php');
	
	$auth_row = pl_cal_token_verify(
		isset($_GET['user_id']) ? $_GET['user_id'] : null,
		$_GET['token']);
	
	if (false === $auth_row) {
		header('HTTP/1.1 401 Unauthorized');
		header('Content-Type: text/plain; charset=utf-8');
		exit("Invalid calendar subscription token.\n");
	}
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

$user_id = (int) $auth_row['user_id'];

pl_menu_get('act_type');
pl_menu_get('category');
pl_menu_get('funding');
pl_menu_get('yes_no');

$interval = 30;
if(isset($_SESSION['def_ical_interval']) && is_numeric($_SESSION['def_ical_interval'])) {
	$interval = $_SESSION['def_ical_interval'];
}
$current_date = date('U');
$end_date = $current_date + ($interval * 24 * 60 * 60); // End Date range
$current_date = $current_date - (2*24*60*60); // Show 2 days prior
$current_date = date('Y-m-d',$current_date);
$end_date = date('Y-m-d',$end_date);


// Main Code
$sql = "SELECT activities.*, cases.number
		FROM activities
		LEFT JOIN cases ON activities.case_id = cases.case_id
		WHERE 1 
		AND activities.user_id='{$user_id}'
		AND act_date >= '{$current_date}'
		AND act_date <= '{$end_date}'
		ORDER BY act_date DESC, act_time DESC 
		LIMIT 1000;";

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
$file_size = strlen($buffer);

header("Content-Type: text/Calendar");
header("Content-Disposition: attachment; filename=\"pika.ics\"");
header("Content-Length: {$file_size}");

pika_exit($buffer);

?>
