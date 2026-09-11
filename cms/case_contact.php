<?php

require_once('pika-danio.php');
pika_init();

require_once('pikaMisc.php');

require_once('pikaCase.php');

$case_id = pl_grab_get('case_id');
$number = pl_grab_get('number');
$main_html = array();  // Values for the main HTML template.
$content_t = array();
$extra_url = pl_simple_url();
$base_url = pl_settings_get('base_url');

/*	This page had no case_id validation and no authorization check of any
	kind, and both of those had consequences beyond reading a page you should
	not see.

	pikaMisc::htmlContactList('case_contact') builds a pikaCase out of the
	query string and calls resetConflictStatus(false) on it, which ends in
	$this->save(). So:

	  - With a case_id the caller could not read, the request still wrote
	    cases.poten_conflicts on that case. Confirmed on this codebase: a user
	    in a group with no read_all, no read_office and no intake was refused
	    case.php?case_id=N outright and could still flip the flag on case N
	    from this page.

	  - With no case_id at all, `new pikaCase(null)` is a NEW record, so the
	    save INSERTed a case row -- and plBase::getNextID() had already taken
	    the next case number out of the `counters` table to build it. Every
	    hit created another case and consumed another case number from the
	    organisation's numbering sequence.

	So validate the id, then authorize before anything loads. edit_case is the
	right permission because this is the form for adding a contact to a case,
	and ops/add_case_contact.php -- the handler behind it -- checks edit_case.
*/
$case_id = filter_var($case_id, FILTER_VALIDATE_INT, array('options' => array('min_range' => 1)));

if ($case_id === false)
{
	header("Location: {$base_url}/case_list.php");
	exit();
}

$case1 = new pikaCase($case_id);

if (!pika_authorize('edit_case', $case1->getValues()))
{
	http_response_code(403);
	$main_html['page_title'] = 'Adding a Case Contact';
	$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; <a href=\"{$base_url}/case_list.php\">Cases</a>";
	$main_html['content'] = 'This case is not viewable.';
	$buffer = pl_template('templates/default.html', $main_html);
	pika_exit($buffer);
}

$content_t = pikaMisc::htmlContactList('case_contact');

// Create a case number label.
if ($number)
{
	$num = $number;
}

else
{
	$num = 'This Case';
}

$main_html['content'] = pl_template('subtemplates/case_contact_list.html', $content_t);
$main_html['page_title'] = "Adding a Case Contact";
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> 
	&gt; <a href=\"{$base_url}/case_list.php\">Cases</a> 
	&gt; <a href=\"{$base_url}/case.php?case_id={$case_id}\">" . pl_html_escape($num) . "</a> 
	&gt; Adding a Case Contact";


$buffer = pl_template('templates/default.html', $main_html);
pika_exit($buffer);

?>
