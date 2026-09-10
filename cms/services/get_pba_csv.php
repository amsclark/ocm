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
// Every column here has to exist in pb_attorneys. Four did not: 'Active?'
// read a column named active when the column is named enabled, and
// 'Phone Notes Alt', 'Address Line 3' and 'Type' have no column at all in
// this schema. Each one was an undefined array key on every row of every
// export, and each produced an always-empty column in the file.
$columns = array('PBA ID', 'Active?', 'Attorney ID', 'First Name', 'Middle Name', 'Last Name', 'Extra name', 
                 'Email', 'Firm', 'Phone Notes', 'Address Line 1', 'Address Line 2', 
                 'City', 'State', 'ZIP', 'County', 'Language', 'Practice Areas', 'Notes', 'Last Case');
$t->set_header($columns);

$my_pikaPbAttorney = new pikaPbAttorney();
$pba_db = $my_pikaPbAttorney->getPbAttorneyDB();

// DBResult::fetchRow() rather than mysql_fetch_assoc(): the mysql_* functions
// were removed in PHP 7 and only work here through the compatibility shim in
// app/extralib. DBResult picks the right driver by itself.
while ($row = DBResult::fetchRow($pba_db))
{
  $report_row['pba_id'] = $row['pba_id'];
  $report_row['active'] = $row['enabled'];
  $report_row['atty_id'] = $row['atty_id'];
  $report_row['first_name'] = $row['first_name'];
  $report_row['middle_name'] = $row['middle_name'];
  $report_row['last_name'] = $row['last_name'];
  $report_row['extra_name'] = $row['extra_name'];
  $report_row['email'] = $row['email'];
  $report_row['firm'] = $row['firm'];
  $report_row['phone_notes'] = $row['phone_notes'];
  $report_row['address'] = $row['address'];
  $report_row['address2'] = $row['address2'];
  $report_row['city'] = $row['city'];
  $report_row['state'] = $row['state'];
  $report_row['zip'] = $row['zip'];
  $report_row['county'] = $row['county'];
  $report_row['languages'] = $row['languages'];
  $report_row['practice_areas'] = $row['practice_areas'];
  $report_row['notes'] = $row['notes'];
  $report_row['last_case'] = $row['last_case'];
  $t->add_row($report_row);
}

$t->display();
exit();

?>
