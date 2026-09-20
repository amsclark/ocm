<?php
chdir('../../');

require_once('pika-danio.php');

pika_init();

require_once('pikaCase.php');
require_once('pikaContact.php');
require_once('pikaCompen.php');
require_once('plFlexList.php');
require_once('pikaTempLib.php');


/*	This form prints the case number, the client's name and full address, and
	the case's billing lines. Nothing here read a permission: $case_id came
	straight off the query string, so before this gate any signed-in user could
	read any case's billing here, including a case that case.php refuses them.

	The gate is read access to the case, not the `reports` group flag. The Docs
	tab reaches these per-case reports for ordinary users, so a report-level
	flag would take case printing away from everyone outside the system group.

	The id is checked and the case looked up before pikaCase is constructed,
	which is the order case.php uses, for two reasons.

	plBase::__construct() answers a SELECT that matched no row with
	trigger_error(), and the pl error handler turns that into the generic "This
	page is currently unavailable" screen and exits. That screen is a different
	answer from the refusal below, so a caller who cannot read any case could
	walk case_id values and tell a real case from a number that is no case at
	all. Measured before this change: an unknown id answered 200 and the generic
	screen, an existing case the caller may not read answered 403.

	An absent, empty or non-integer case_id is worse. plBase treats it as a new
	record, allocates the next free case id and fills the rest with nulls, so the
	form would print a report for a case that does not exist yet.
*/
$base_url = pl_settings_get('base_url');

$case_id = filter_var(pl_grab_get('case_id', null, 'number'), FILTER_VALIDATE_INT,
	array('options' => array('min_range' => 1)));

if (false === $case_id)
{
	pl_case_not_viewable($base_url);
}

$case_exists = DB::query("SELECT case_id FROM cases WHERE case_id = "
	. (int) $case_id . " LIMIT 1");

if (!$case_exists || DBResult::numRows($case_exists) < 1)
{
	pl_case_not_viewable($base_url);
}

$case = new pikaCase($case_id);
$a = $case->getValues();

if (!is_array($a) || empty($a['case_id']) || !pika_authorize('read_case', $a))
{
	pl_case_not_viewable($base_url);
}

if($a['client_id']) {
	$contact = new pikaContact($a['client_id']);
	$b = $contact->getValues();
} else {$b = array();}

$a = array_merge($a, $b);

$a['primary_client_name'] = pikaTempLib::plugin('text_name','',$a);
$a['username'] = $auth_row['username'];
$a['full_address'] = pikaTempLib::plugin('text_address','',$a,'',array("output=html"));


// generate the billing table
$result = pikaCompen::getCaseCompenBill($case_id);

$bill_list = new plFlexList();
$bill_list->template_file = 'reports/compen_bill/compen_bill.html';

$total_bill = 0;

while ($row = DBResult::fetchRow($result)) {
	$row['billing_date'] = pikaTempLib::plugin('text_date','billing_date',$row['billing_date']);
	$total_bill += $row['billing_amount'];
	
	$bill_list->addRow($row);
}

$a['billing_table'] = $bill_list->draw();
$a['total_bill'] = $total_bill;

$default_template = new pikaTempLib('reports/compen_bill/compen_bill.html',$a);
$buffer = $default_template->draw();

pika_exit($buffer);
?>
