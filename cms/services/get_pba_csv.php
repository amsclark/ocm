<?php
ini_set('display_errors', 1);
ini_set('display_startup_errors', 1);
error_reporting(E_ALL);


// 2022-06-02 Alex Clark, Metatheria LLC

chdir('../');

require_once ('pika-danio.php');
pika_init();
require ('pikaPbAttorney.php');
require_once ('pikaMisc.php');
require_once ('plCsvReportTable.php');
require_once ('plCsvReport.php');

$filter = array();
$county = pl_grab_get('county');
$languages = pl_grab_get('languages');
$practice_areas = pl_grab_get('practice_areas');
$last_name = pl_grab_get('last_name');


if ($county)
{
	$filter['county'] = $county;
}

if ($languages)
{
	$filter['languages'] = $languages;
}

if ($practice_areas)
{
	$filter['practice_areas'] = $practice_areas;
}

if ($last_name)
{
	$filter['last_name'] = $last_name;
}


$report_title = 'Pro Bono Attorneys List';

$t = new plCsVReport();
$t->title = $report_title;
$columns = array('PBA ID', 'Active?', 'Attorney ID', 'First Name', 'Middle Name', 'Last Name', 'Extra name', 
                 'Email', 'Firm', 'Phone Notes', 'Phone Notes Alt', 'Address Line 1', 'Address Line 2', 'Address Line 3', 
                 'City', 'State', 'ZIP', 'County', 'Language', 'Practice Areas', 'Notes', 'Last Case', 'Type');
$t->set_header($columns);

//$my_pikaPbAttorney = new pikaPbAttorney();
//$pba_db = $my_pikaPbAttorney->getPbAttorneyDB();
$row_count = 0;
$pba_db = pikaPbAttorney::getPbAttorneys($filter, $row_count, 'atty_name', 'ASC', 0, 0);

//while ($row = DBResult::fetchRow($pba_db)) // swap this if/when they upgrade to ocm 8
while ($row = DBResult::fetchRow($pba_db))
{
  $report_row['pba_id'] = $row['pba_id'];
  $report_row['active'] = $row['active'];
  $report_row['atty_id'] = $row['atty_id'];
  $report_row['first_name'] = str_replace(' ', ' ', $row['first_name']);
  $report_row['middle_name'] = str_replace(' ', ' ', $row['middle_name']);
  $report_row['last_name'] = str_replace(' ', ' ', $row['last_name']);
  $report_row['extra_name'] = str_replace(' ', ' ', $row['extra_name']);
  $report_row['email'] = $row['email'];
  $report_row['firm'] = $row['firm'];
  $report_row['phone_notes'] = $row['phone_notes'];
  $report_row['phone_notes_alt'] = $row['phone_notes_alt'];
  $report_row['address'] = str_replace(' ', ' ', $row['address']);
  $report_row['address2'] = str_replace(' ', ' ',  $row['address2']);
  $report_row['address3'] = str_replace(' ', ' ', $row['address3']);
  $report_row['city'] = $row['city'];
  $report_row['state'] = $row['state'];
  $report_row['zip'] = $row['zip'];
  $report_row['county'] = $row['county'];
  $report_row['languages'] = $row['languages'];
  $report_row['practice_areas'] = str_replace(' ', ' ', $row['practice_areas']);
  $report_row['notes'] = $row['notes'];
  $report_row['last_case'] = $row['last_case'];
  $report_row['pb_type'] = $row['pb_type'];
  $t->add_row($report_row);
}


$t->display();
exit();

?>
