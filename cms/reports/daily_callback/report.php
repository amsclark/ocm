<?php
// 04-22-2011 - caw - modified after upgrade to remove pl_process_comma_vals 
chdir('../../');

require_once ('pika-danio.php'); 
pika_init();
require_once('pikaMisc.php');


$report_title = "Daily Callback Report";
$report_name = "daily_callback";

$base_url = pl_settings_get('base_url');

$report_format = pl_grab_post('report_format');
$date_start = pl_grab_post('date_start');
$date_end = pl_grab_post('date_end');
$status = pl_grab_post('status');

$menu_case_status = pl_menu_get('case_status');
$menu_problem = pl_menu_get('problem');
$staff_array = pikaMisc::fetchStaffArray();

if ('csv' == $report_format)
{
	require_once ('app/lib/plCsvReportTable.php');
	require_once ('app/lib/plCsvReport.php');
	$t = new plCsvReport();
}

else
{
	require_once ('app/lib/plHtmlReportTable.php');
	require_once ('app/lib/plHtmlReport.php');
	$t = new plHtmlReport();
}



// run the report

$sql = "SELECT contacts.first_name, contacts.middle_name, contacts.last_name, 
				number, status, open_date, problem, user_id, notes
		FROM cases
		LEFT JOIN contacts ON contacts.contact_id = cases.client_id
		WHERE 1";
$columns = array('Client', 'Status', 'Open Date', 'Problem', 'Number', 'Counsel', 'Notes');
					
// handle the crazy date range selection
$range1 = $range2 = "";
$safe_date_start = mysql_real_escape_string(pl_date_mogrify($date_start));
$safe_date_end = mysql_real_escape_string(pl_date_mogrify($date_end));

if ($date_start && $date_end) {
	$sql .= " AND open_date >= '{$safe_date_start}' AND open_date <= '{$safe_date_end}'";
} elseif ($date_start) {
	$sql .= " AND open_date >= '{$safe_date_start}'";
} elseif ($cle) {
	$sql .= " AND open_date <= '{$safe_date_end}'";
}


$x = pl_process_comma_vals($status);
if ($x != false)
{
	$sql .= " AND status IN $x";
}

$sql .= " AND (office != 'T' OR office IS NULL)";



$sql .= " ORDER BY contacts.last_name ASC, contacts.first_name ASC";


$t->title = $report_title;
//$t->display_row_count(false);
$t->set_header($columns);


$result = mysql_query($sql) or trigger_error();
while ($row = mysql_fetch_assoc($result))
{
	$r = array();
	$r['client_name'] = pl_text_last_name($row);
	$r['status'] = pl_array_lookup($row['status'],$menu_case_status);
	$r['open_date'] = pl_date_unmogrify($row['open_date']);
	$r['problem'] = pl_array_lookup($row['problem'],$menu_problem);
	$r['number'] = $row['number'];
	$r['user_id'] = pl_array_lookup($row['user_id'],$staff_array);
	$r['notes'] = $row['notes'];
	$t->add_row($r);
}


if($show_sql) {
	$t->set_sql($sql);
}

$t->display();
exit();

?>
