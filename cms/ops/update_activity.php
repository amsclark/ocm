<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/
// 2012 point release update appending url so user will return to case listing instead of case when updating case related activity from case listing

chdir('../');

require_once ('pika-danio.php');
pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

require_once('pikaActivity.php');

/**
 * Fill in hours from a start/end time range when no hours were entered.
 *
 * The Calendar entry form (act_type 'C', subtemplates/activityC.html)
 * captures Start Time and End Time and has no hours field at all, and this
 * handler reads hours straight out of the POST -- so every calendar time
 * entry saved as 0 hours. It stayed on the calendar and was invisible to
 * the Time Codes report and to every timekeeping total.
 *
 * An hours value the user actually typed always wins; this only fills an
 * empty or zero one. The range is measured against a fixed date so a span
 * that would cross midnight derives nothing and is left for explicit
 * entry.
 *
 * A future-dated entry is a scheduled appointment, not work that has been
 * done, so it is left alone. Today and earlier derive.
 *
 * @param pikaActivity $activity
 * @return void
*/
function pika_derive_hours_from_timerange($activity)
{
	/*	Read through getValues() rather than $activity->hours. plBase has
		__get but no __isset, so isset() on one of these is always false and
		a guard written that way would silently overwrite an hours value the
		user did type.
	*/
	$values = $activity->getValues();
	
	$current_hours = isset($values['hours']) ? (float) $values['hours'] : 0.0;
	
	if ($current_hours > 0)
	{
		return;
	}
	
	$act_date = isset($values['act_date']) ? trim((string) $values['act_date']) : '';
	
	if ($act_date !== '')
	{
		$act_timestamp = strtotime($act_date);
		
		if ($act_timestamp !== false && date('Y-m-d', $act_timestamp) > date('Y-m-d'))
		{
			return;
		}
	}
	
	$start = isset($values['act_time']) ? trim((string) $values['act_time']) : '';
	$end = isset($values['act_end_time']) ? trim((string) $values['act_end_time']) : '';
	
	if ($start === '' || $end === '' || $start === '00:00:00' || $end === '00:00:00')
	{
		return;
	}
	
	$start_timestamp = strtotime('1970-01-01 ' . $start);
	$end_timestamp = strtotime('1970-01-01 ' . $end);
	
	if ($start_timestamp === false || $end_timestamp === false || $end_timestamp <= $start_timestamp)
	{
		return;
	}
	
	$activity->hours = round(($end_timestamp - $start_timestamp) / 3600.0, 4);
}


// VARIABLES
$base_url = pl_settings_get('base_url');
$act_interval = pl_settings_get('act_interval');

$act_id = pl_grab_post('act_id');
$act_date = pl_grab_post('act_date', date('Y-m-d'));
$act_url = pl_grab_post('act_url');
$act_type = pl_grab_post('act_type', 'C');
$funding = pl_grab_post('funding');
$case_id = pl_grab_post('case_id');
$screen = pl_grab_post('screen', 'act');
$user_id = pl_grab_post('user_id');
$pba_id = pl_grab_post('pba_id');

$next_act = pl_grab_post('next_act');
$close_act = pl_grab_post('close_act');
$cancel = pl_grab_post('cancel');

$a = pl_clean_form_input($_POST);


// BEGIN MAIN CODE...

// AMW 2013-05-03 - $act_url is getting set to "case.php" in some cases, which causes a error due to the missing case_id.  This is 
// an ugly workaround for that.  Future TODO: fix the code that sets $act_url in activity.php
/*
if ("case.php" == $act_url)
{
	$act_url = "index.php";
}
*/


/*	The backdating lock. activity.php greys the date, funding and hours
	fields out once an activity is more than activity_lock_max_days old,
	but that is a disabled attribute in the markup and nothing more: any
	POST that did not come from that form ignored it, and the setting was
	advice rather than a rule.
	
	Both dates are checked. The submitted one stops a new record being
	backdated into the locked window; on an edit the stored one stops a
	locked record being dragged forward to a date that is not locked.
	
	A refusal returns to the form rather than dying, because the common
	case is an honest user with a stale page open.
*/
if (!$cancel)
{
	$locked_date = $act_date;
	
	if ($act_id && is_numeric($act_id))
	{
		$existing = new pikaActivity($act_id);
		$existing_values = $existing->getValues();
		$existing_date = isset($existing_values['act_date']) ? $existing_values['act_date'] : '';
		
		if (pika_activity_date_locked($existing_date))
		{
			$locked_date = $existing_date;
		}
	}
	
	if (pika_activity_date_locked($locked_date))
	{
		$lock_return = "{$base_url}/activity.php?date_lock_error=1"
			. '&act_id=' . urlencode((string) $act_id)
			. '&case_id=' . urlencode((string) $case_id)
			. '&act_type=' . urlencode((string) $act_type)
			. '&act_date=' . urlencode((string) $locked_date);
		
		header("Location: {$lock_return}");
		exit();
	}
}

// The user is saving the activity record.
if($act_id && is_numeric($act_id)) {
	$activity = new pikaActivity($act_id);
	$act_row = $activity->getValues();
	if (pika_authorize('edit_act', $act_row)) 
	{	
		$activity->setValues($a);
		pika_derive_hours_from_timerange($activity);
		$activity->hours = pikaActivity::roundHoursByInterval($activity->hours,$act_interval);
		$activity->save();
	}
} else if (!$cancel) {
	$activity = new pikaActivity();
	unset($a['act_id']);
	$activity->setValues($a);
	pika_derive_hours_from_timerange($activity);
	$activity->hours = pikaActivity::roundHoursByInterval($activity->hours,$act_interval);
	
	if ($activity->act_type == 'K' && file_exists(pl_custom_directory() . '/extensions/create_tickler/create_tickler.php'))
	{
		require_once(pl_custom_directory() . '/extensions/create_tickler/create_tickler.php');
		$z = $activity->getValues();
		$z['case_number'] = null;
		$z['client_name'] = null;
		$z['case_status'] = null;
		$z['tickler_email'] = array();

		if (isset($z['user_id']))
		{
			require_once('pikaContact.php');
			$tickler_owner = new pikaUser($z['user_id']);
			$z['summary'] .= " (" . substr($tickler_owner->first_name, 0, 1);
			//$z['summary'] .= substr($tickler_owner->middle_name, 0, 1);
			$z['summary'] .= substr($tickler_owner->last_name, 0, 1) . ")";
		}
		
		if ($z['case_id'] > 0)
		{
			require_once('pikaCase.php');
			$case0 = new pikaCase($z['case_id']);
			$z['case_number'] = $case0->number;
			$z['case_status'] = $case0->status;

			if ($case0->client_id > 0)
			{
				require_once('pikaContact.php');
				$client = new pikaContact($case0->client_id);
				$z['client_name'] = $client->first_name . " ";
				$z['client_name'] .= $client->middle_name . " ";
				$z['client_name'] .= $client->last_name . " ";
				$z['client_name'] .= $client->extra_name;
			}
			
			/*	This built the link from $_SERVER['REQUEST_SCHEME'] and
				$_SERVER['SERVER_NAME']. The link goes into a tickler
				notification email, and Apache fills SERVER_NAME from the
				request's Host header unless UseCanonicalName is On, which it
				is not by default -- so a request carrying
				"Host: attacker.example" produced a notification whose link
				pointed at the attacker. REQUEST_SCHEME is also not always
				set, which is an undefined-index warning of its own.
			
				pl_canonical_origin() prefers the canonical_url setting and
				validates the fallback. It returns '' when it cannot work out
				an origin; a relative link is still usable from inside the
				application, and a wrong absolute one is not.
			
				The 2015 note that used to sit here reasoned that case_link
				exposes nothing secret, so neither source was dangerous. That
				is true of what the link discloses and beside the point: the
				risk is what the link sends the reader to.
			*/
			$z['case_link'] = pl_canonical_origin();
			$z['case_link'] .= pl_settings_get('base_url');
			$z['case_link'] .= '/case.php?case_id=' . $case0->case_id;

			if ($case0->user_id > 0)
			{
				require_once('pikaContact.php');
				$user0 = new pikaUser($case0->user_id);
				$z['tickler_email'][] = $user0->email;
			}
			
			if ($case0->cocounsel1 > 0)
			{
				require_once('pikaContact.php');
				$user1 = new pikaUser($case0->cocounsel1);
				$z['tickler_email'][] = $user1->email;
			}
			
			if ($case0->cocounsel2 > 0)
			{
				require_once('pikaContact.php');
				$user2 = new pikaUser($case0->cocounsel2);
				$z['tickler_email'][] = $user2->email;
			}

			if ($case0->cocounsel3 > 0)
			{
				require_once('pikaContact.php');
				$user3 = new pikaUser($case0->cocounsel3);
				$z['tickler_email'][] = $user3->email;
			}
			
			if (strlen($case0->office) > 0)
			{
				if (DBResult::numRows(DB::query("SHOW TABLES LIKE 'office_email'")) == 1)
				{
					$x = DB::escapeString($case0->office);
					$y = DBResult::fetchRow(DB::query("SELECT label FROM office_email WHERE value = '{$x}'"));
					$z['tickler_email'][] = $y['label'];
				}
			}
		}
				
		create_tickler($z) or trigger_error('Extension failed.');
	}
	
	$activity->save();
}

// 2012 point release update appending url so user will return to case listing instead of case when updating case related activity from case listing 
/* if ($next_act) {
	header("Location: {$base_url}/activity.php?act_type={$act_type}&act_date={$act_date}&case_id={$case_id}&funding={$funding}&user_id={$user_id}&pba_id={$pba_id}&act_url={$act_url}");
} else if ($close_act){
	if ($case_id && is_numeric($case_id)) {
		header("Location: {$base_url}/case.php?case_id={$a['case_id']}");
	} else {
		if($act_url == 'case.php') { $act_url = 'cal_day.php';}
		header("Location: {$base_url}/{$act_url}?cal_date={$act_date}");
	}
} else {
	if ($case_id && is_numeric($case_id)) {
		header("Location: {$base_url}/case.php?case_id={$case_id}");
	} else {
		header("Location: {$base_url}/cal_day.php?cal_date={$act_date}");
	}
}
*/

if ($next_act) 
{
	header("Location: {$base_url}/activity.php?act_type={$act_type}&act_date={$act_date}&case_id={$case_id}&funding={$funding}&user_id={$user_id}&pba_id={$pba_id}&act_url={$act_url}");
} 

else if ($close_act)
{
	if ($case_id && is_numeric($case_id) && strpos($act_url,'case.php') !== false) 
	{
		if (strpos($act_url,'case_id') !== false)
		{	
			header("Location: {$base_url}/{$act_url}");	
		}
		
		else 
		{
			header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
		}
	}
	
	else if(preg_match('/cal_(day|week|adv).php$/',$act_url)) 
	{
		header("Location: {$base_url}/{$act_url}?cal_date={$act_date}");
	}
	
	else 
	{
		header("Location: {$base_url}/{$act_url}");
	}
} 

else 
{
	if ($case_id && is_numeric($case_id)) 
	{
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
	}
	
	else 
	{
		header("Location: {$base_url}/cal_day.php?cal_date={$act_date}");
	}
}

exit();

?>