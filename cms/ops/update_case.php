<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com       */
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

require_once('pikaCase.php');

// VARIABLES
$base_url = pl_settings_get('base_url');


if ( $_SERVER['REQUEST_METHOD'] === 'POST' ){ 
	$case_id = pl_grab_post('case_id', 0);
	$action = pl_grab_post('action');
	$screen = pl_grab_post('screen');
	$submitted_data = $_POST;
} else {
	$case_id = pl_grab_get('case_id', 0);
	$action = pl_grab_get('action');
	$screen = pl_grab_get('screen');
	$submitted_data = $_GET;
}


// BEGIN MAIN CODE...

if (!$case_id) 
{
	trigger_error('No case ID was provided.');
}

// The user is saving the case record.
$case_data = new pikaCase($case_id);

// Check permissions first.
$case_row = $case_data->getValues();
$allow_edits = pika_authorize('edit_case', $case_row);
	
if ($allow_edits) 
{
	if (pl_settings_get('open_outcomes') && $case_row['close_date'] === null 
		&& isset($submitted_data['close_date'])
		&& strlen($submitted_data['close_date']) > 0)
	{
		$screen = 'outcomes';
	}
	
	/*	setValues() writes any column of the cases row that the request
		happens to carry. The case screens do not offer these five, so a
		value for one of them can only have been added to the request by
		hand: case_id is the primary key, created and last_changed are
		stamped by the database, intake_user_id records who took the intake
		and is meant to stay put afterwards, and poten_conflicts is written
		by the conflict check. Drop them before the write.
		
		Listing the columns that are allowed instead would be the stronger
		rule, but this one page saves more than twenty case tabs, each with
		its own set of fields, so the list would be long and would go stale.
		Denying the handful that are always system-owned is what closes the
		hole that matters, which is a user rewriting their own audit trail.
	*/
	$form_input = pl_clean_form_input($submitted_data);
	$denied_fields = array(
		'case_id',
		'created',
		'last_changed',
		'intake_user_id',
		'poten_conflicts'
		);
	
	foreach ($denied_fields as $denied_field)
	{
		unset($form_input[$denied_field]);
	}
	
	$case_data->setValues($form_input);
	
	/*	client_id arrives in the request, so it cannot be pasted into a
		query. Bind it.
	*/
	$check_valid_client_id_sql = "select contact_id from contacts where contact_id = ?";
        $valid_client_id_result = DB::preparedQuery($check_valid_client_id_sql,array($case_data->getValue('client_id'))) or trigger_error("SQL: " . $check_valid_client_id_sql . " Error: " . DB::error());
        $num_valid_client_id = DBResult::numrows($valid_client_id_result);
        if ($num_valid_client_id == 0)
        {
          $case_data->setValue('client_id', '');
        }
	
	
	$case_data->save();
	
	if (array_key_exists('outcomes', $_POST))
	{
		// AMW - It would be more efficient to pass all outcomes to a 
		// "pikaCase::recordOutcomes($array)" method that could run one
		// INSERT with multiple rows, but I don't think it needs to be
		// optimized at this point.
		$case_data->deleteOutcomes();
				
		foreach ($_POST['outcomes'] as $key => $val)
		{
			$case_data->addOutcome($key, $val);
		}
	}
	
	else if (array_key_exists('single_outcome', $_POST))
	{
		$case_data->deleteOutcomes();
		$case_data->addOutcome(pl_grab_post('single_outcome', null, 'number'), 1);
	}
	
	// AC - clear outcomes if the problem code changes
        if (array_key_exists('prior_problem', $_POST) && array_key_exists('problem', $_POST) && $_POST['prior_problem'] != $_POST['problem'])
        {
                // $case_id comes from the request; bind it rather than pasting it in.
                $reset_sql = "DELETE FROM outcomes WHERE case_id = ?";
                DB::preparedQuery($reset_sql,array($case_id)) or trigger_error("SQL: " . $reset_sql . " Error: " . DB::error());
        }

}

$client_id = $case_data->getValue('client_id');
$case_id = $case_data->getValue('case_id');

if ('confirm_client' == $action)
{
	header("Location: {$base_url}/contact.php?contact_id={$client_id}&case_id={$case_id}");
}

else
{
	header("Location: {$base_url}/case.php?case_id={$case_id}&screen={$screen}");
}

exit();

?>
