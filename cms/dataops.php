<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

/*
This file handles new/update/delete data requests, and redirects the user to the appropriate
screen after the data operation is completed.
*/

require_once ('pika_cms.php');

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

/*	Keep a redirect on this site.
	
	Several handlers below redirect to a URL the request supplied, so the
	request chose where a logged-in staff member's browser went next. That is
	worth having on a legal aid system: the credential-phishing page it sends
	them to is reached from a real link inside the application they trust.
	
	Anything absolute, protocol-relative, or carrying a CR or LF -- which would
	split the Location header and let the request add headers of its own -- is
	replaced with the site root.
*/
function safe_redirect_url($url, $base_url)
{
	$url = trim((string) $url);
	
	if (preg_match('#^https?://#i', $url) || preg_match('#^//#', $url))
	{
		return $base_url . '/';
	}
	
	return str_replace(array("\r", "\n"), '', $url);
}

// VARIABLES
$pk = new pikaCms;
$action = pl_grab_var('action', null, 'REQUEST');
$screen = pl_grab_var('screen', 'info', 'REQUEST');
$case_id = pl_grab_var('case_id', null, 'REQUEST');
$relation_code = pl_grab_var('relation_code', null, 'REQUEST');
$base_url = pl_settings_get('base_url');

// this will store the current case data, to be used to fill out forms
$case_row = NULL;
// end VARIABLES


// BEGIN MAIN CODE...

// Enforce security level permissions
if (array_key_exists('case_id', $_REQUEST) && $_REQUEST['case_id'])
{
	$result = $pk->fetchCase($_REQUEST['case_id']);
	$case_row = DBResult::fetchRow($result);
	
	$allow_edits = pika_authorize('edit_case', $case_row);
	
	if ($action && !$allow_edits)
	{
		$action = 'not_allowed';
	}
}

/*	Authorize the handlers the case gate above never sees.
	
	That gate only ever ran when the request happened to carry a case_id.
	Everything this file can do to something that is not a case -- update a
	contact, add an alias, delete a timeslip, create or edit a pro bono attorney
	-- ran with no authorization check at all, because leaving case_id out of
	the request was enough to skip the whole block.
*/
switch ($action)
{
	// Contact writes are authorized against the cases the contact is attached
	// to: pika_authorize('edit_contact', ...) walks them and grants only if the
	// user can edit at least one of them.
	case 'update_contact':
	case 'new_alias':
	
	$dataops_contact_id = pl_grab_var('contact_id', null, 'REQUEST');
	
	if (!$dataops_contact_id
		|| !pika_authorize('edit_contact', array('contact_id' => $dataops_contact_id)))
	{
		$action = 'not_allowed';
	}
	
	break;
	
	
	// Deleting an activity has its own permission, including a self-delete
	// branch. It was reachable here by act_id alone.
	case 'delete_act':
	
	$dataops_act_id = pl_grab_var('act_id', null, 'POST');
	$dataops_act_row = null;
	
	if ($dataops_act_id)
	{
		$dataops_act_res = $pk->fetchActivity($dataops_act_id);
		
		if ($dataops_act_res)
		{
			$dataops_act_row = DBResult::fetchRow($dataops_act_res);
		}
	}
	
	if (!is_array($dataops_act_row) || !pika_authorize('delete_act', $dataops_act_row))
	{
		$action = 'not_allowed';
	}
	
	break;
	
	
	// Pro bono attorney records are administered from pb_attorneys.php, which
	// gates on the group's pba flag. The same records were writable straight
	// through this handler with no flag at all.
	case 'add_pb':
	case 'update_pb':
	
	if ($auth_row['pba'] != true && $auth_row['group_name'] != 'system')
	{
		$action = 'not_allowed';
	}
	
	break;
}

// determine what, if any, action to perform
switch($action)
{
	case 'add_activity':
	
	if ($_REQUEST['cancel'])
	{
		header('Location: ' . safe_redirect_url($_REQUEST['act_url'], $base_url));
		break;
	}
	
	// TODO:  this may be a bug
	if ($_REQUEST['user_id'] != $auth_row['user_id']
	&& !$auth_row['edit_all'])
	{
		$action = 'not_allowed';
	}
	
	$a = pl_grab_vars('activities');
	
	$act_id = $pk->newActivity($a);
	
	unset($a);
	
	// decide where to go from here
	if ($_REQUEST['close_act'])
	{
		header('Location: ' . safe_redirect_url($_REQUEST['act_url'], $base_url));
	}
	
	else
	{
		$act_url = urlencode($_REQUEST['act_url']);
		$act_date_tmp = pl_date_mogrify($_REQUEST['act_date']);
		header("Location: activity.php?screen=compose&user_id={$_REQUEST['user_id']}&pba_id={$_REQUEST['pba_id']}&case_id={$_REQUEST['case_id']}&funding={$_REQUEST['funding']}&act_date=$act_date_tmp&completed={$_REQUEST['completed']}&act_url=$act_url&act_type={$_REQUEST['act_type']}");
	}
	
	break;
	
	
	case 'update_activity':
	
	$act_url = pl_grab_post('act_url');
	if ($_POST['action']
	&& $_REQUEST['user_id'] != $auth_row['user_id']
	&& !$auth_row['edit_all'])
	{
		$action = 'not_allowed';
	}
	
	$a = pl_grab_vars('activities');
	
	// enforce security level permissions
	if (!pika_authorize('edit_act', $a))
	{
		// set up template, then display page
		$plTemplate["page_title"] = "Editing activity record";
		$plTemplate["content"] = 'access denied';
		
		echo pl_template($plTemplate, 'templates/default.html');
		echo pl_bench('results');
		exit();
	}

	$pk->updateActivity($a);
	
	if (FALSE == $plEnableSpellcheck || !$spellcheck)
	{
		header('Location: ' . safe_redirect_url($act_url, $base_url));
		
	}
	
	// activate dictionary function
	if (TRUE == $plEnableSpellcheck)
	{
		$pspell_link = pspell_new("en");
		
		/*	this code parses the 'notes' field.  As it comes across words,
		it will spellcheck them.  If the word doesn't pass the
		spellcheck, it is marked with "not spelled right" tags
		*/
		unset($word);
		unset($sc);
		
		// 2013-08-13 AMW - Removed =& for compatibility with PHP 5.3.
		$k = $a['notes'];
		for ($j = 0; $j < strlen($k); $j++)
		{
			if (($k[$j] >= 'a' && $k[$j] <= 'z') ||
			($k[$j] >= 'A' && $k[$j] <= 'Z'))
			{
				$word = $word . $k[$j];
			}
			
			else
			{
				if ($word)
				{
					$sc = $sc . spellcheck($word);
					unset($word);
				}
				
				$sc = $sc . $k[$j];
			}
		}
		
		$sc = $sc . spellcheck($word);
	}
	
	header('Location: ' . safe_redirect_url($act_url, $base_url));
	
	break;
	
	
	case 'update_activity_bulk':
	
	$act_date = pl_grab_var('act_date', date('Y-m-d'), 'POST', 'date');
	
	$completed = pl_grab_var('completed', array(), 'POST', 'array');
	$hours = pl_grab_var('hours', array(), 'POST', 'array');
	
	/*	The check that belongs here was commented out.
		
		The array keys are activity ids straight from the POST body, so with
		nothing in its place this loop would mark complete, and mint billable
		time slips against, any activity id in the database -- not only the ones
		the day view actually rendered for this user.
		
		Authorize per row, and skip a row the user cannot edit rather than
		failing the whole submit, so one stale id in a form does not throw away
		a day of time entry.
	*/
	foreach ($hours as $key => $val)
	{
		$bulk_row = null;
		$bulk_res = $pk->fetchActivity($key);
		
		if ($bulk_res)
		{
			$bulk_row = DBResult::fetchRow($bulk_res);
		}
		
		if (!is_array($bulk_row) || !pika_authorize('edit_act', $bulk_row))
		{
			continue;
		}
		
		// Update checked records to be completed
		if (isset($completed[$key]) && true == $completed[$key])
		{
			$pk->updateActivity(array('act_id' => $key, 'completed' => true));
		}
		
		// Create time slips for any records which had time entered
		if ($val)
		{
			$pk->duplicateActivity($key, array('hours' => $val, 'completed' => "1", 'act_type' => 'T', 'act_date' => date('Y-m-d'), 'act_time' => date('H:m:00')));
		}
	}
	
	header("Location: cal_day.php?act_date=$act_date");
	break;
	
	
	case 'update_case':
	
	if (!$case_id)
	{
		die(pika_error_notice('Pika is sick',
		'Ran into trouble when updating the case record'));
	}
	
	$x = pl_grab_vars('cases');
	$pk->updateCase($x);
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
	
	break;
	
	
	// add a new contact, or link an existing contact, to a case
	case 'add_case_contact':
	
	$screen = pl_grab_var('screen', 'REQUEST', 'act');
	
	if (is_null($case_id) || is_null($relation_code))
	{
		die(pika_error_notice('Pika is sick',
		'Ran into trouble when adding the case contact'));
	}
	
	$thiscon = pl_grab_var('thiscon', null, 'POST');
	if (is_numeric($thiscon))
	{
		// An existing contact record is being added to this case
		if (!$pk->addCaseContact($case_id, $thiscon, $relation_code))
		{
			die(pika_error_notice('Pika is sick', "This contact is already added to this case."));
		}
		
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
		
	}
	
	else
	{
		// A new contact record is being added to this case.
		
		$a = pl_grab_vars('contacts');
		
		// take care of those nasty "masked" fields
		if ($phone_a || $phone_b)
		{
			$a["phone"] = "$phone_a-$phone_b";
		}
		
		else if (!isset($a['phone']))
		{
			$a["phone"] = "";
		}
		
		if ($phone_alt_a || $phone_alt_b)
		{
			$a["phone_alt"] = "$phone_alt_a-$phone_alt_b";
		}
		
		else if (!isset($a['phone_alt']))
		{
			$a["phone_alt"] = "";
		}
		
		if ($_POST['ssn0'] || $_POST['ssn1'] || $_POST['ssn2'])
		{
			$a['ssn'] = "{$_POST['ssn0']}-{$_POST['ssn1']}-{$_POST['ssn2']}";
		}
		
		else if (!isset($a['ssn']))
		{
			$a['ssn'] = "";
		}
		
		$contact_id = $pk->newContact($a);
		
		/*
		If we get past the first pl_query(), then it should be safe to add
		the relation
		*/
		if (!$pk->addCaseContact($case_id, $contact_id, $relation_code))
		{
			die(pika_error_notice('Pika is sick', "This contact is already added to this case."));
		}
		
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
		
		
	}
	
	break;
	
	/*
	The user is coming from intake.php, and wants to create a new case.  The client
	is either an existing contact or needs a new contact record created.
	*/
	case 'new_case':
	
	$thiscon = pl_grab_var('thiscon', null, 'POST');
	
	/*	used when adding a new case for a client with an existing contact record
	don't import any data from previous cases, however
	*/
	if (is_numeric($thiscon))
	{
		// add the case record...
		$a = $plDvs['cases'];
		
		// set default office value
		$a['office'] = $pikaDefOffice;
		
		// set the first client as the primary client
		$a['client_id'] = $thiscon;
		
		if (true == $plSettings['autonumber_on_new_case'])
		{
			$a['number'] = 'auto';
		}
		
		$a = array_merge($a, pl_grab_vars('cases'));
		
		$case_id = $pk->newCase($a);
		
		// Now link the client to the case
		$pk->addCaseContact($case_id, $thiscon, CLIENT);
		
		/*	the user probably came here from the list of existing contacts on
		the intake process, which means "action=dup_contact_last" is on the
		URL.  We don't want this get pulled into $con_url (where it will
		get re-executed), so do a HTTP redirect to a "clean" url.
		
		Alternatively, the links on the existing contacts list could be
		changed to POST forms.
		
		Go directly into the intake tab.
		*/
		
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen=elig");
	}
	
	/*	The user is creating a new case record, but first a new contact record for the primary
	client.  When done, redirect to the new case on case.php.
	*/
	else
	{
		// Add the new contact record...
		$con = pl_grab_vars('contacts');
		
		// handle input masks
		if ($_POST['phone_a'] || $_POST['phone_b'])
		{
			$con["phone"] = "{$_POST['phone_a']}-{$_POST['phone_b']}";
		}
		
		else if (!isset($con['phone']))
		{
			$con["phone"] = "";
		}
		
		if ($phone_alt_a || $phone_alt_b)
		{
			$con["phone_alt"] = "$phone_alt_a-$phone_alt_b";
		}
		
		else if (!isset($con['phone_alt']))
		{
			$con["phone_alt"] = "";
		}
		
		if ($_POST['ssn0'] || $_POST['ssn1'] || $_POST['ssn2'])
		{
			$con['ssn'] = "{$_POST['ssn0']}-{$_POST['ssn1']}-{$_POST['ssn2']}";
		}
		
		else if (!isset($con['ssn']))
		{
			$con['ssn'] = "";
		}
		
		$contact_id = $pk->newContact($con);
		
		
		// Add any user-supplied aliases
		$al_first_name = pl_grab_var('al_first_name', array(), 'POST', 'array');
		$al_middle_name = pl_grab_var('al_middle_name', array(), 'POST', 'array');
		$al_last_name = pl_grab_var('al_last_name', array(), 'POST', 'array');
		$al_extra_name = pl_grab_var('al_extra_name', array(), 'POST', 'array');
		$for_limit = sizeof($al_first_name);
		$j = 0;
		for ($j = 0; $j < $for_limit; $j++)
		{
			if ($al_first_name[$j] || $al_middle_name[$j] || $al_last_name[$j] || $al_extra_name[$j]
			|| $al_ssn[$j] || $al_state_id[$j])
			{
				$alias_data['first_name'] = $al_first_name[$j];
				$alias_data['middle_name'] = $al_middle_name[$j];
				$alias_data['last_name'] = $al_last_name[$j];
				$alias_data['extra_name'] = $al_extra_name[$j];
				$alias_data['ssn'] = $al_ssn[$j];
				$alias_data['state_id'] = $al_state_id[$j];
				$alias_data['contact_id'] = $contact_id;
				
				$pk->newAlias($alias_data);
			}
		}
		
		
		// Now add the case record...
		$a = $pikaDvs['cases'];
		
		// set default office value
		$a['office'] = $pikaDefOffice;
		
		// set the first client as the primary client
		$a['client_id'] = $contact_id;
		
		if (true == $plSettings['autonumber_on_new_case'])
		{
			$a['number'] = 'auto';
		}
		
		$a = array_merge($a, pl_grab_vars('cases'));
		
		$case_id = $pk->newCase($a);
		
		// Now link the client to the case
		$pk->addCaseContact($case_id, $contact_id, CLIENT);
		
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen=elig");
	}
	
	break;
	
	
	
	/*
	The user is coming from a "New Case" link, and wants to create a new case and bypass the
	client intake process, going instead straight to eligibility screening.
	*/
	case 'new_case_no_client':
	
	$screen = pl_grab_var('screen');
	
	pl_table_init('cases');
	$a = $plDvs['cases'];
	
	// set default office value
	$a['office'] = $pikaDefOffice;
	
	if (true == $plSettings['autonumber_on_new_case'])
	{
		$a['number'] = 'auto';
	}
	
	$a = array_merge($a, pl_grab_vars('cases'));
	
	/*
	Since no client is added, and no conflict check will be performed, poten_conflicts
	will still be set to its default value of 1.  Fix this.
	*/
	$a['poten_conflicts'] = '0';
	
	$case_id = $pk->newCase($a);
	
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
	
	break;
	
	
	
	// used when duplicated an existing case (ie. client comes in with 2 issues)
	case 'dup':
	
	if (is_null($old_case_id))
	{
		die(pika_error_notice('Pika is sick',
		'Ran into trouble when duplicating this case'));
	}
	
	$case_id = $pk->duplicateCase($old_case_id);
	
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
	
	break;
	
	
	// I think this is DEPRECATED now...
	/*	used when adding a new case for a previous client
	don't import any data from previous cases, however
	*/
	case 'dup_contact_last999':
	
	if (is_null($contact_id))
	{
		die(pika_error_notice('Pika is sick',
		'Ran into trouble when adding the new case'));
	}
	
	// add the case record...
	$a = $pikaDvs['cases'];
	
	// set default office value
	$a['office'] = $pikaDefOffice;
	
	// set the first client as the primary client
	$a['client_id'] = $contact_id;
	
	if (true == $plSettings['autonumber_on_new_case'])
	{
		$a['number'] = 'auto';
	}
	
	$a['referred_by'] = $referred_by;
	
	/*	should probably just run pl_grab_vars(cases) if any more case
	fields are	needed
	*/
	
	$case_id = $pk->newCase($a);
	
	
	// Now link the client to the case
	$pk->addCaseContact($case_id, $contact_id, CLIENT);
	
	
	/*	the user probably came here from the list of existing contacts on
	the intake process, which means "action=dup_contact_last" is on the
	URL.  We don't want this get pulled into $con_url (where it will
	get re-executed), so do a HTTP redirect to a "clean" url.
	
	Alternatively, the links on the existing contacts list could be
	changed to POST forms.
	
	Go directly into the intake tab.
	*/
	
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
	
	break;
	
	
	// I think this is DEPRECATED now...
	
	/*	The user is creating a new case record, but first a new contact record for the primary
	client.  When done, redirect to the new case on case.php.
	*/
	
	case 'new_contact_new_case999':
	
	// Add the new contact record...
	$con = pl_grab_vars('contacts');
	
	// handle input masks
	if ($_POST['phone_a'] || $_POST['phone_b'])
	{
		$con["phone"] = "{$_POST['phone_a']}-{$_POST['phone_b']}";
	}
	
	else
	{
		$con["phone"] = "";
	}
	
	if ($phone_alt_a || $phone_alt_b)
	{
		$con["phone_alt"] = "$phone_alt_a-$phone_alt_b";
	}
	
	else
	{
		$con["phone_alt"] = "";
	}
	
	if ($_POST['ssn0'] || $_POST['ssn1'] || $_POST['ssn2'])
	{
		$con['ssn'] = "{$_POST['ssn0']}-{$_POST['ssn1']}-{$_POST['ssn2']}";
	}
	
	else
	{
		$con['ssn'] = "";
	}
	
	$contact_id = $pk->newContact($con);
	
	
	// Now add the case record...
	$a = $pikaDvs['cases'];
	
	// set default office value
	$a['office'] = $pikaDefOffice;
	
	// set the first client as the primary client
	$a['client_id'] = $contact_id;
	
	if (true == $plSettings['autonumber_on_new_case'])
	{
		$a['number'] = 'auto';
	}
	
	/*	for SMRLS (should probably just run pl_grab_vars(cases) if any more case fields are
	needed)
	*/
	$a['referred_by'] = $referred_by;
	
	$case_id = $pk->newCase($a);
	
	
	// Now link the client to the case
	$pk->addCaseContact($case_id, $contact_id, CLIENT);
	
	
	
	$plIntakeType = 'a';
	if ('fast' == $plIntakeType)
	{
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen=fast");
	}
	
	else
	{
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen=info");
	}
	
	break;
	
	
	/*	Update an existing contact record with the data submitted, then redirect
	to the previous screen.
	*/
	case 'update_contact':
	
	$a = pl_grab_vars('contacts');
	
	if ($phone_a || $phone_b)
	{
		$a["phone"] = "$phone_a-$phone_b";
	}
	
	else if (!isset($a['phone']))
	{
		$a["phone"] = "";
	}
	
	if ($phone_alt_a || $phone_alt_b)
	{
		$a["phone_alt"] = "$phone_alt_a-$phone_alt_b";
	}
	
	else if (!isset($a['phone']))
	{
		$a["phone_alt"] = "";
	}
	
	if ($_POST['ssn0'] || $_POST['ssn1'] || $_POST['ssn2'])
	{
		$a['ssn'] = "{$_POST['ssn0']}-{$_POST['ssn1']}-{$_POST['ssn2']}";
	}
	
	else if (!isset($a['ssn']))
	{
		$a['ssn'] = "";
	}
	
	$pk->updateContact($a);
	
	header('Location: ' . safe_redirect_url($con_url, $base_url));
	
	break;
	
	
	case 'add_pb':
	
	$a = pl_grab_vars('pb_attorneys');
	$pba_id = $pk->newPbAttorney($a);
	
	header("Location: pb_attorneys.php?screen=edit_pb&pba_id=$pba_id");
	
	break;
	
	
	case 'update_pb':
	
	$a = pl_grab_vars('pb_attorneys');
	
	$result = $pk->updatePbAttorney($a);
	
	header("Location: pb_attorneys.php");
	
	break;
	
	
	case 'set_case_user':
	
	// Same GET-mutation shape as delete_conflict below: reassigning the
	// handling attorney (and stamping their last_case date) ran off
	// REQUEST, so it fired on a plain GET with no token. The only caller
	// is the POST form in subtemplates/assign_atty.html, which already
	// ships %%[csrf_field]%%, so reading POST-only costs nothing and makes
	// the file-level pl_csrf_check() actually cover this action.
	$case_id = pl_grab_post('case_id');
	$user_id = pl_grab_post('user_id');
	$field = pl_grab_post('field');
	$x = "";
	
	/*	Precedence bug: && binds tighter than ||, so this guard parsed as
		
			(($case_id && $user_id && 'user_id' == $field)
			 || 'cocounsel1' == $field
			 || 'cocounsel2' == $field)
		
		The case_id and user_id presence check therefore only applied to the
		handling-attorney field. A request naming either co-counsel field
		entered the block with no case and no user: with a real case_id and an
		empty user_id it wrote '' into cocounsel1 or cocounsel2, silently
		clearing that slot -- and pika_authorize() grants case access off those
		two columns, so clearing one revokes a staffer's access to the case.
		
		The intent is "we have a case and a user, and the target column is one
		of the three we allow", so the alternation needs its own parentheses.
	*/
	if ($case_id && $user_id
		&& ('user_id' == $field || 'cocounsel1' == $field || 'cocounsel2' == $field))
	{
		$result = $pk->fetchCase($case_id);
		$a = DBResult::fetchRow($result);
		$a[$field] = $user_id;
		$pk->updateCase($a);
		// also update this attorney's last_case_assign field
		$pk->updateStaff(array('user_id' => $user_id, 'last_case' => date("Y-m-d")));
	}
	
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen=info");
	
	break;

	
	case 'set_case_pba':
	
	/*	GET-driven mutation, the same shape as delete_conflict below. Assigning
		a pro bono attorney to a case slot rode on a plain <a href> built by
		pb_attorneys.php, so anything that could make a logged-in browser issue
		that URL reassigned the case with no token to stop it. Read the inputs
		from POST only, so the file-level pl_csrf_check() actually covers this
		action and a GET that still reaches this handler arrives with nothing
		to act on.
		
		$field and $pba_id were never read from the request in this file at
		all, so both were undefined here and the handler could not assign
		anything: $x stayed empty, updateCase() rewrote the row unchanged and
		setPbAttorneyLastCase() ran against a null id. Reading them from POST
		is what makes the action do the job pb_attorneys.php links it for.
	*/
	$case_id = pl_grab_post('case_id');
	$field = pl_grab_post('field');
	$pba_id = pl_grab_post('pba_id');
	
	$x = "";
	
	if ('pba_id1' == $field || 'pba_id2' == $field || 'pba_id3' == $field)
	{
		$x = $field;
	}
	
	// Not a POST from the attorney picker: no case, no attorney, or a target
	// column outside the three slots. Nothing to act on, so send the user home
	// rather than rewrite a case row for no reason.
	if (!is_numeric($case_id) || !is_numeric($pba_id) || !$x)
	{
		header("Location: {$base_url}/");
		exit();
	}
	
	$result = $pk->fetchCase($case_id);
	$a = DBResult::fetchRow($result);
	
	if (!is_array($a))
	{
		header("Location: {$base_url}/");
		exit();
	}
	
	$a[$x] = $pba_id;
	
	$pk->updateCase($a);
	
	// also update this PBA's last_case_assign field
	$pk->setPbAttorneyLastCase($pba_id, date("Y-m-d"));
	
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen=pb");
	
	break;
	
	
	case 'set_password':
	
	/*	Two faults, and either one on its own defeats the whole control.
		
		The old-password check compared the stored hash to the submitted
		plaintext with !=, so it could only ever succeed when both sides were
		empty -- which is exactly the account you least want it to succeed on.
		
		Worse, neither guard had an exit() after its redirect. header() only
		queues a header; execution carried straight on to setPassword(). A
		wrong current password, or two new passwords that did not match, still
		changed the password, and the browser then followed the error redirect
		so the user was told it had failed.
		
		That makes "confirm your current password" do nothing at all, which is
		the control standing between a hijacked session or an unattended
		workstation and permanent ownership of the account.
		
		password.php is the real change-password screen and verifies correctly
		(md5 for rows that predate the bcrypt migration, then password_verify).
		Do the same here rather than leave a second, weaker door on the same
		operation.
	*/
	/*	The hash has to be re-read from the users table. $auth_row on any
		request after the login one is built from the sessions table joined to
		users and groups, and that select list does not include the password
		column -- reading $auth_row['password'] here yields '' and rejects even
		the correct password, which is a working change-password screen turned
		off. password.php re-reads the row too, via new pikaUser(); that class
		is not on dataops.php's include_path, so read the one column directly.
	*/
	$stored_hash = '';
	$pass_result = DB::preparedQuery(
		'SELECT password FROM users WHERE user_id = ? LIMIT 1',
		array($auth_row['user_id'])
	);
	$pass_row = DBResult::fetchRow($pass_result);
	
	if (is_array($pass_row) && isset($pass_row['password']))
	{
		$stored_hash = (string) $pass_row['password'];
	}
	
	$old_pass_in = isset($_POST['oldpass']) ? (string) $_POST['oldpass'] : '';
	
	if ('' === $old_pass_in
		|| '' === $stored_hash
		|| (md5($old_pass_in) !== $stored_hash && !password_verify($old_pass_in, $stored_hash)))
	{
		header('Location: password.php?error_code=1');
		exit();
	}
	
	if (!isset($_POST['newpass1'])
		|| '' === (string) $_POST['newpass1']
		|| $_POST['newpass1'] != $_POST['newpass2'])
	{
		header('Location: password.php?error_code=2');
		exit();
	}
	
	$pk->setPassword($auth_row['user_id'], $_POST['newpass1']);
	
	header('Location: index.php');
	
	break;
	
	
	case 'delete_act':
	
	$act_id = pl_grab_var('act_id', null, 'POST');
	$result = $pk->deleteActivity($act_id);
	
	header('Location: cal_day.php');
	
	break;
	
	
	case 'delete_conflict':
	
	// GET-driven mutation. These reads used pl_grab_var(), which defaults
	// to the REQUEST superglobal, so
	//   GET dataops.php?action=delete_conflict&conflict_id=X&case_id=1
	// deleted the row outright. Authorization IS enforced (the edit_case
	// gate above), but authorization is not CSRF: any page a logged-in
	// staff member visits could fire this from an <img src>.
	//
	// The file-level pl_csrf_check() at the top of dataops.php already
	// covers the POST side, so the missing half is exactly what
	// ops/delete_activity.php and ops/delete_contact.php do -- read the
	// mutation inputs from POST only, so a GET that still reaches this
	// handler arrives with nothing to act on.
	//
	// Nothing links here: the live "remove" control posts to
	// ops/delete_conflict.php (subtemplates/case_screen.html), and the
	// only builder of the GET URL is the vestigial "OLD WAY" block in
	// case.php, whose $clients_html is assigned but whose output block is
	// commented out.
	//
	// A separate $conflict_case_id keeps the outer $case_id (read from
	// REQUEST at the top of the file, and used by the redirect) intact
	// when the POST body carries nothing, so a bare GET still lands the
	// user back on a case page instead of on case.php?case_id=.
	$conflict_id = pl_grab_post('conflict_id');
	$conflict_case_id = pl_grab_post('case_id');
	
	if (!is_null($conflict_id) && !is_null($conflict_case_id))
	{
		$result = $pk->deleteConflict($conflict_id, $conflict_case_id);
		$case_id = $conflict_case_id;
	}
	
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen=info");
	
	break;
	
	
	case 'new_alias':
	
	$data = pl_grab_vars('aliases');
	$pk->newAlias($data);
	
	header("Location: contact.php?contact_id={$data['contact_id']}");
	
	break;
	
	
	/*	The criminal-charges handlers were removed here.
		
		They were dead in every sense. Nothing in the tree posts
		add_case_charges or update_case_charges; no charges case tab and no
		module renderer ever existed to receive the screen=charges redirects
		they issued; and new_install.sql never creates the case_charges or
		charges tables they query, seeding only two orphan rows in counters.
		
		They were also dangerous while they sat here. Both reached pikaCms
		methods that interpolated request data straight into SQL --
		lookupChargeByStatute() built WHERE statute='$statute' by hand -- and
		update_case_charges read $_POST directly, so it bypassed pl_grab_var()
		and pl_clean_form_input() with it. update_case_charges also took no
		case_id until after the work was done, and the case gate at the top of
		this file only runs when the request carries one, so leaving it out
		skipped authorization entirely.
		
		The four unreachable pikaCms methods went with them.
	*/
	
	case 'add_compen':
	
	$a = pl_grab_vars('compens');
	$pk->addCompen($a);
	
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen=compen");
	
	
	break;
	
	
	case 'add_survey_response':
	
	$q_ids = pl_grab_var('q_ids', array(), 'POST', 'array');
	$answers = pl_grab_var('answers', array(), 'POST', 'array');
	$case_id = pl_grab_var('case_id', null, 'POST');
	
	if (sizeof($q_ids) != sizeof($answers))
	{
		echo "An error has occurred";
		exit();
	}
	
	$j = sizeof($q_ids);
	
	for ($i = 0; $i < $j; $i++)
	{
		$pk->addSurveyResponse($q_ids[$i], $case_id, $answers[$i]);
	}
	
	header("Location: survey.php?action=close");
	
	break;

	
	case 'save_prefs':
	
	$_SESSION['def_office'] =  pl_grab_var('def_office', null, 'POST');
	$_SESSION['intake'] =  pl_grab_var('intake', null, 'POST');
	$_SESSION['paging'] =  pl_grab_var('paging', null, 'POST', 'number');
	$_SESSION['font_size'] =  pl_grab_var('font_size', null, 'POST');
	$_SESSION['popup'] =  pl_grab_var('popup', null, 'POST', 'boolean');
	$_SESSION['theme'] = pl_grab_var('theme', null, 'POST');
	$_SESSION['r_format'] = pl_grab_var('r_format', null, 'POST');
	session_write_close();
	header("Location: prefs.php?user_id={$auth_row['user_id']}");
	//pl_session_freeze();
	
	break;
	
	
	case 'not_allowed':
	
	// $window_title was never assigned in this file, so the title was empty
	// and every hit logged an undefined-variable warning.
	die(pika_error_notice('Case', 'Editing of this case is not allowed'));
	break;
	
	
	case 'add_event':
	
	if (array_key_exists('cancel', $_REQUEST))
	{
		header('Location: ' . safe_redirect_url($_REQUEST['act_url'], $base_url));
		break;
	}
	
	// TODO - security?
	
	$a = pl_grab_vars('events');
	//$user_array = pl_grab_var('{user_id}', array(), 'POST', 'array');
	$a['user_ids'] = ','. implode(',', $user_id) . ',';
	$event = new event();
	$event->setValues($a);
	
	// decide where to go from here
	$act_url = urlencode($_REQUEST['act_url']);
	$act_date_tmp = pl_date_mogrify($_REQUEST['act_date']);
	header("Location: event.php?screen=compose&user_id={$_REQUEST['user_id']}&pba_id={$_REQUEST['pba_id']}&case_id={$_REQUEST['case_id']}&funding={$_REQUEST['funding']}&act_date=$act_date_tmp&completed={$_REQUEST['completed']}&act_url=$act_url&act_type={$_REQUEST['act_type']}");
	
	break;
	
	case 'add_ex_appt':
	
	/*
	$case_id = pl_grab_var('case_id');
	$data = array();
	$data = pl_grab_var('sched_select', $data, 'POST', 'array');
	$summary = pl_grab_var('summary');
	list($dtstart, $dtend, $contact) = explode(',', $data);
	$contact = strtolower($contact);
	list($first_name, $last_name) = explode(" ", $contact);
	$username = substr($first_name, 0, 1) . $last_name;
	
	pika_xchg_appt_add($username, $dtstart, $dtend, $summary);
	*/
	
	$sched_select = $_POST['sched_select'];  // an array
	$case_id = pl_grab_var('case_id', null, 'POST');
	$summary = pl_grab_var('summary', null, 'POST');
	$case_number = pl_grab_var('number', null, 'POST');
	
	// Extract the filename, username from $sched_select.
	$n = explode('|', $sched_select[0]);
	$record_id = $n[0];
	$ex_username = $n[1];
	
	if ($case_id > 0 && strlen($sched_select) > 0)
	{
		require_once('nusoap.php');
		$parameters = array('server_name' => 'NEWTON', 
				'username' => $ex_username, 
				'record_id' => $record_id, 
				'summary' => $case_number . ': ' . $summary);
		$s = new soapclient('http://newton.freelawyers.org:8000/exchange4pika/ex_tol_assign.php');
		$result = $s->call('ex_tol_assign', $parameters);
		if ($s->fault)
		{
			die(pika_error_notice('Error', "Case transfer error: $error" . $client->faultstring));
		}
		
		else if (0 == $result)
		{
			header("Location: {$base_url}/case.php?case_id={$case_id}&screen=sched&failure=1");
		}
		
		else 
		{
			header("Location: case.php?case_id={$case_id}&screen=sched&status=result");
		}
	}
	
	else 
	{
		header("Location: {$base_url}/case.php?case_id={$case_id}&screen=sched&failure=1");
	}
		
	break;
	
	
	// Hack.
	case 'toledo_holding':
	
	$x = pl_grab_vars('cases');
	
	if (!$x['case_id'])
	{
		die(pika_error_notice('Pika is sick',
		'No case ID and/or Office ID supplied.'));
	}
	
	// Set LAL Transfer on old case.
	
	$u = array();
	$u['case_id'] = $x['case_id'];
	$u['transfer_to'] = pl_grab_var('trans_office', 'POST', 'X');
	$pk->updateCase($u);
	
	// Create new transfer cases with appropriate defaults.
	
	$res = $pk->fetchCase($x['case_id']);
	$y = DBResult::fetchRow($res);
	$y['office'] = pl_grab_var('trans_office', 'POST', 'X');
	$y['number'] = 'auto';
	$y['in_holding_pen'] = '1';
	$y['status'] = '1';
	$y['user_id'] = '1000004';
	$y['cocounsel'] = '';
	$y['cocounsel2'] = '';
	$y['transfer_to'] = '';
	$new_case_id = $pk->newCase($y);
	
	$res = DB::query("SELECT * FROM conflict WHERE case_id='{$x['case_id']}'");
	while ($row = DBResult::fetchRow($res))
	{
		$pk->addCaseContact($new_case_id, $row['contact_id'], $row['relation_code']);
	}
	
	$res = $pk->fetchNotes($x['case_id']);
	while ($row = DBResult::fetchRow($res))
	{
		$row['case_id'] = $new_case_id;
		$row['hours'] = '0';
		$pk->newActivity($row);
	}

	$x['status'] = '4';
	$pk->updateCase($x);

	header("Location: toledo_holding.php?case_id={$x['case_id']}&new_case_id=$new_case_id&office={$y['office']}");

	break;
	
	
	case 'reopen_case':
	
	$case_id = pl_grab_post('case_id');
	$screen = pl_clean_html(pl_grab_post('screen'));
	
	if (!$case_id)
	{
		die(pika_error_notice('Pika is sick',
		'No case ID and/or Office ID supplied.'));
	}
	
	$u = array();
	$u['case_id'] = $case_id;
	$u['status'] = '1';
	$u['close_date'] = '';
	$u['close_code'] = '';
	$u['reject_code'] = '';
	$u['destroy_date'] = '';
	// Toledo-specific field.
	$u['disposition_status'] = '';
	$pk->updateCase($u);
	
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");

	break;
	
	
	case 'transfer-soap':

	require_once('nusoap.php');
	
	function transfer_error($section_name)
	{
		global $s;
		$error = $s->getError();
		
		$plTemplate['content'] = "Case transfer error ($section_name): $error";
		$plTemplate['page_title'] = 'Case Transfer';
		$plTemplate['nav'] = "<a href=\".\" class=light>$pikaNavRootLabel</a> &gt; Case Transfer";
		echo pl_template($plTemplate, 'templates/default.html');
		echo pl_bench('results');
		exit();
	}
	
	$case_id = pl_grab_var('case_id', 'GET');
	$s = new soapclient('http://skunky/gila/transfer-soap.php');
	$staff_array = $pk->fetchStaffArray();
	$owner_name = pl_settings_get('owner_name');
	
	// cases record.
	$r = $pk->fetchCase($case_id);
	$case_row = $case_row2 = DBResult::fetchRow($r);
	
	unset($case_row['user_id']);
	unset($case_row['cocounsel1']);
	unset($case_row['cocounsel2']);
	unset($case_row['intake_user_id']);
		
	// This hack prevents zeros from converting to NULLs during transfer.
	foreach ($case_row as $key => $val)
	{
		if ($val == "0.00")
		{
			$case_row[$key] = "zero";
		}
	}
	
	$parameters = array($case_row);
	$t_case_id = $s->call('newCase', $parameters);

	if ($s->getError())
	{
		transfer_error('newCase');
	}
	
	// contacts and conflicts.
	$r = $pk->fetchCaseContacts($case_id);
	while ($row = DBResult::fetchRow($r))
	{		
		$parameters = array($row);
		$t_contact_id = $s->call('newContact', $parameters);
		if ($s->getError())
		{
			transfer_error('newContact');
		}
		
		$parameters = array($t_case_id, $t_contact_id, $row['relation_code']);
		$result = $s->call('addCaseContact', $parameters);
		if ($s->getError())
		{
			transfer_error('addCaseContact');
		}
	}
	
	// activities - notes and timekeeping.
	$r = $pk->fetchNotes($case_id);
	while ($notes = DBResult::fetchRow($r))
	{
		$notes['case_id'] = $t_case_id;

		$atty_name = pl_array_lookup($notes['user_id'], $staff_array);
		$notes['notes'] .= "\n\n===\nEntered by {$atty_name}, {$owner_name}";
		$notes['notes'] .= ", {$case_row['number']}";
		unset($notes['user_id']);
		
		$parameters = array($notes);
		$result = $s->call('newActivity', $parameters);
		if ($s->getError())
		{
			transfer_error('newActivity');
		}
	}
	
	// Set the original case to transferred status.
	$case_row2['status'] = 4;
	$pk->updateCase($case_row2);

	$plTemplate['content'] = "Transfer of case # '{$case_id}' completed, new case id # is '$t_case_id' $t_contact_id.";
	$plTemplate['page_title'] = 'Case Transfer';
	$plTemplate['nav'] = "<a href=\".\" class=light>$pikaNavRootLabel</a> &gt; Case Transfer";
	echo pl_template($plTemplate, 'templates/default.html');
	echo pl_bench('results');
	
	break;
	
	
	//Questionnaire by DTK

	case "save_quest":
		$user_id = $auth_row["user_id"];
		$questionnaire_id = pl_grab_var('questionnaire_id', null, 'REQUEST');
		$completed_id = pl_grab_var('completed_id', null, 'REQUEST');
		$case_id = pl_grab_var('case_id', null, 'REQUEST');
		$answer = pl_grab_var('answer', null, 'REQUEST');
		$answer_id = pl_grab_var('answer_id', null, 'REQUEST');
		$q_action = pl_grab_var('q_action', null, 'REQUEST');
		$response_text = pl_grab_var('response_text', null, 'REQUEST');
		$response_text = addslashes($response_text);
		
		if (!$completed_id) {
			$completed_sql  = "SELECT completed_id FROM q_completed WHERE questionnaire_id=$questionnaire_id ";
			$completed_sql .= "AND case_id=$case_id ORDER BY completed_time DESC LIMIT 1";
//			echo $completed_sql . "<br>";
			$results = DB::query($completed_sql);
			while ($row = DBResult::fetchRow($results)) {
				$completed_id = $row["completed_id"];
			}

			if (!$completed_id) {
				$completed_sql = "INSERT INTO q_completed (questionnaire_id, case_id, user_id, completed_time) ";
				$completed_sql .= "VALUES ($questionnaire_id, $case_id, $user_id, CURDATE())";
//				echo $completed_sql . "<br>";
				DB::query($completed_sql);
				$completed_sql  = "SELECT completed_id FROM q_completed WHERE questionnaire_id=$questionnaire_id ";
				$completed_sql .= "AND case_id=$case_id AND user_id=$user_id ORDER BY completed_time DESC LIMIT 1";
//				echo $completed_sql . "<br>";
				$results = DB::query($completed_sql);
				while ($row = DBResult::fetchRow($results)) {
					$completed_id = $row["completed_id"];
				}
			} else {
				$completed_sql = "UPDATE q_completed SET ";
				$completed_sql .= "user_id=$user_id, completed_time=CURDATE() WHERE completed_id=$completed_id";
				DB::query($completed_sql);
				echo $completed_sql . "<br>";
			}
		}
		
		$response_sql  = "SELECT response_id FROM q_responses WHERE completed_id=$completed_id AND question_id=$question_id ORDER BY response_id DESC LIMIT 1";
//		echo $response_sql . "<br>";
		$results = DB::query($response_sql);
		while ($row = DBResult::fetchRow($results)) {
			$response_id = $row["response_id"];
		}
		
		if (!$response_id) {
			$response_sql  = "INSERT INTO q_responses (completed_id, question_id, response_text, answer_id) ";
			$response_sql .= "VALUES ($completed_id, $question_id, '$response_text', $answer_id) ";
		} else {
			$response_sql  = "UPDATE q_responses SET response_text='$response_text', answer_id=$answer_id ";
			$response_sql .= "WHERE response_id=$response_id";
		}
//		echo $response_sql . "<br>";
		DB::query($response_sql);
//		echo "<a href=quest_answer.php?case_id=$case_id&questionnaire_id=$questionnaire_id&answer_id=$answer_id&case_id=$case_id&completed_id=$completed_id>Next</a>";
		header("Location: quest_answer.php?case_id=$case_id&questionnaire_id=$questionnaire_id&answer_id=$answer_id&case_id=$case_id&completed_id=$completed_id");
	break;

	
	default:
	
	// Same undefined $window_title as the not_allowed case above.
	die(pika_error_notice('Error', "Error:  invalid action was specified."));
	
	break;
}

// end of 'action' section

exit();

?>
