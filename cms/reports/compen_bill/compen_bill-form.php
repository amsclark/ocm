<?php
chdir('../../');

require_once('pika-danio.php');

pika_init();

require_once('pikaCase.php');
require_once('pikaContact.php');
require_once('pikaCompen.php');
require_once('plFlexList.php');
require_once('pikaTempLib.php');


$case_id = pl_grab_get('case_id');

$case = new pikaCase($case_id);
$a = $case->getValues();

/*	This form prints the case number, the client's name and full address, and
	the case's billing lines. Nothing above reads a permission: $case_id comes
	straight off the query string, so before this gate any signed-in user could
	read any case's billing here, including a case that case.php refuses them.

	The gate is read access to the case, not the `reports` group flag. The Docs
	tab reaches these per-case reports for ordinary users, so a report-level
	flag would take case printing away from everyone outside the system group.

	An empty or unknown case row is refused rather than passed on, because
	pika_authorize('read_case', ...) reads $row['user_id'] and would be
	judging a row that does not exist.
*/
$base_url = pl_settings_get('base_url');

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
