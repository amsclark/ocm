<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.net        */
/**********************************/


require_once ('pika-danio.php');
pika_init();

// This page performs its state changes on a GET: the action is dispatched
// out of the query string and the links that trigger it are plain <a href>
// markup, so a hidden token field is not available as a defence here.
// On a non-POST request pl_csrf_check() falls through to the same-site
// check, which refuses a mutation that a foreign page initiated and needs
// nothing from the markup. See pl_request_cross_site_verdict() in pl.php.
pl_csrf_check();
require_once('pikaActivity.php');
require_once('pikaMisc.php');
require_once('pikaTempLib.php');
require_once('pikaCase.php');


// VARIABLES
$buffer = '';

$case_id = pl_grab_get('case_id');
$action = pl_grab_get('action');
$elapsed_mins = pl_grab_get('elapsed_mins');
$end_butt = pl_grab_get('end');
$pause_butt = pl_grab_get('pause');

$act_row = pl_clean_form_input($_GET);

/*	pl_clean_form_input() copies only the keys that were submitted, so on a
	"(No Case #)" timer - a supported path, see the default a few lines down -
	there is no case_id key at all and both reads of it below are undefined-key
	warnings on PHP 8. Setting the key once changes no outcome, because
	is_numeric(null) and is_numeric(undefined) are both false.
*/
if (!array_key_exists('case_id',$act_row))
{
	$act_row['case_id'] = null;
}

/*	This page had no authorization check at all. It takes case_id from the
	query string and hands it to the case_menu plugin and to pikaCase, so a
	signed-in user whose group grants no access to a case still read that
	case's number and the client's name off a page case.php answers 403 for.

	Ending the timer is a write, and it was ungated too: the branch further
	down builds an Activity out of this same query string and saves it
	against the case, so a caller with no access to the case could file a
	time slip on it. That branch needs edit_case. read_act and edit_act are
	not substitutes - they answer for the activity, not for the case it
	lands on.

	The row for the decision comes from a plain SELECT rather than from
	pikaCase or pikaCms::fetchCaseList(): a pikaCase built on an id that
	names no case calls trigger_error() and prints the generic error screen
	at HTTP 200, which both tells the caller the id is unused and loses the
	refusal, and fetchCaseList() does not select intake_user_id, which
	pika_authorize() reads.

	A case_id that is not a positive integer, and one that names no case,
	answer exactly as a case the caller may not read. Naming no case at all
	is untouched: the "(No Case #)" timer is a supported path.
*/
$timer_case_named = false;

if (!is_null($act_row['case_id']))
{
	/*	An array, as ?case_id[]=42 sends, survives pl_clean_form_input() as
		an array. It is not a case id, so it is not silently dropped here.
	*/
	$timer_case_named = !is_scalar($act_row['case_id'])
		|| '' !== (string) $act_row['case_id'];
}

if ($timer_case_named)
{
	$timer_base_url = pl_settings_get('base_url');

	$timer_case_id = filter_var($act_row['case_id'], FILTER_VALIDATE_INT,
		array('options' => array('min_range' => 1)));

	if (false === $timer_case_id)
	{
		pl_case_not_viewable($timer_base_url);
	}

	$timer_result = DB::query("SELECT * FROM cases WHERE case_id = "
		. (int) $timer_case_id . " LIMIT 1");

	if (!$timer_result || DBResult::numRows($timer_result) < 1)
	{
		pl_case_not_viewable($timer_base_url);
	}

	$timer_case_row = DBResult::fetchRow($timer_result);

	if (!pika_authorize('read_case', $timer_case_row))
	{
		pl_case_not_viewable($timer_base_url);
	}

	if (!is_null($end_butt) && !pika_authorize('edit_case', $timer_case_row))
	{
		pl_case_not_viewable($timer_base_url);
	}
}

if (pl_settings_get('autofill_time_funding') == 0)
{
	$act_row['funding'] = null;
}

$act_interval = pl_settings_get('act_interval');

// Generate cases menu
$filter['show_cases'] = '0';
$filter['user_id'] = $auth_row['user_id'];
$row_count = 0;
$open_cases_result = pikaMisc::getCases($filter,$row_count);
$open_case_menu_array = array();
while($row = DBResult::fetchRow($open_cases_result)) {
	$open_case_menu_array[$row['case_id']] = $row;
}

$case_menu_args = array();

/*	setFunding used to arrive as onchange="setFunding(this.value);" on the
	case menu, and only when this setting was on. The handler has moved to
	js/timer-inline.js for the Content-Security-Policy, so the setting now
	reaches the browser as a class the listener looks for. Binding the
	listener to the menu's id instead would autofill funding on every box,
	including the ones that turned this off.
*/
if (pl_settings_get('autofill_time_funding') == 1)
{
	$case_menu_args[] = 'class=plmenu js-set-funding';
}

$act_row['new_case_menu'] = pikaTempLib::plugin('case_menu', 'case_id',
	$act_row['case_id'], $open_case_menu_array, $case_menu_args);

if(is_numeric($act_row['case_id'])) {
	$case = new pikaCase($act_row['case_id']);
	$act_row['number'] = $case->number;
	
	if (!isset($act_row['funding']) && !$act_row['funding'] 
		&& pl_settings_get('autofill_time_funding') == 1) 
	{
		$act_row['funding'] = $case->funding;
	}
}
if(!isset($act_row['number']) || !$act_row['number']) {$act_row['number'] = '(No Case #)';}
$textformat = new pikaTempLib('subtemplates/textFormat.html',array());
$act_row['textFormat'] = $textformat->draw();

if (!is_null($end_butt))
{
	if($elapsed_mins >= 0)
	{
		$hours = $elapsed_mins / 60;	
	}
	else 
	{
		$hours = 0;
	}
	$act_row['act_date'] = date('Y-m-d');
	$act_row['hours'] = $hours;
	$act_row['user_id'] = $auth_row['user_id'];
	$act_row['completed'] = 1;
	$activity = new pikaActivity();
	if (isset($a['act_id'])) { unset($a['act_id']); }
	$activity->setValues($act_row);
	$activity->hours = $activity->roundHoursByInterval($hours,$act_interval);
	$activity->save();
	$template = new pikaTempLib('subtemplates/timer.html',array(),'timer-close');
} elseif (!is_null($pause_butt)) {
	$template = new pikaTempLib('subtemplates/timer.html',$act_row,'timer-pause');
} else {
	$act_row['act_time'] = pl_time_current_string();
	$template = new pikaTempLib('subtemplates/timer.html',$act_row,'timer');
}







$a['content'] = $template->draw();
$a['page_title'] = "Pop-Up Timer";

$default_template = new pikaTempLib('templates/empty.html',$a);
$buffer = $default_template->draw();
pika_exit($buffer);
?>
