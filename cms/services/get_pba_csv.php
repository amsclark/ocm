<?php

// 2022-06-02 Alex Clark, Metatheria LLC

chdir('../');

require_once ('pika-danio.php');
pika_init();
require ('pikaPbAttorney.php');
require_once ('pikaMisc.php');
require_once ('plCsvReportTable.php');
require_once ('plCsvReport.php');

$report_title = 'Pro Bono Attorneys List';

$t = new plCsVReport();
$t->title = $report_title;
$columns = array('PBA ID', 'Active?', 'Attorney ID', 'First Name', 'Middle Name', 'Last Name', 'Extra name', 
                 'Email', 'Firm', 'Phone Notes', 'Phone Notes Alt', 'Address Line 1', 'Address Line 2', 'Address Line 3', 
                 'City', 'State', 'ZIP', 'County', 'Language', 'Practice Areas', 'Notes', 'Last Case', 'Type');
$t->set_header($columns);

$my_pikaPbAttorney = new pikaPbAttorney();
$pba_db = $my_pikaPbAttorney->getPbAttorneyDB();

//while ($row = DBResult::fetchRow($pba_db)) // swap this if/when they upgrade to ocm 8
while ($row = mysql_fetch_assoc($pba_db))
{
  $report_row['pba_id'] = $row['pba_id'];
  $report_row['active'] = $row['active'];
  $report_row['atty_id'] = $row['atty_id'];
  $report_row['first_name'] = $row['first_name'];
  $report_row['middle_name'] = $row['middle_name'];
  $report_row['last_name'] = $row['last_name'];
  $report_row['extra_name'] = $row['extra_name'];
  $report_row['email'] = $row['email'];
  $report_row['firm'] = $row['firm'];
  $report_row['phone_notes'] = $row['phone_notes'];
  $report_row['phone_notes_alt'] = $row['phone_notes_alt'];
  $report_row['address'] = $row['address'];
  $report_row['address2'] = $row['address2'];
  $report_row['address3'] = $row['address3'];
  $report_row['city'] = $row['city'];
  $report_row['state'] = $row['state'];
  $report_row['zip'] = $row['zip'];
  $report_row['county'] = $row['county'];
  $report_row['languages'] = $row['languages'];
  $report_row['practice_areas'] = $row['practice_areas'];
  $report_row['notes'] = $row['notes'];
  $report_row['last_case'] = $row['last_case'];
  $report_row['pb_type'] = $row['pb_type'];
  $t->add_row($report_row);
}

$t->display();
exit();

?>
