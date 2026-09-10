<?php

chdir('../');

require_once('pika-danio.php');
pika_init();

require_once('pikaMisc.php');
require_once('pikaTempLib.php');

$base_url = pl_settings_get('base_url');
$C = '';

// Build the listing from the reports the CURRENT user may actually run.
//
// pikaMisc::htmlReportList() renders every installed report to anyone with a
// session, so a user with an empty groups.reports column still got the full
// inventory of what this org reports on -- LSC CSR, HUD 9902, VOCA
// victimization, and the rest. Each report already gates itself with
// pika_report_authorize(), so the names were a listing-only disclosure, but
// the listing is the map an attacker uses to pick a target.
//
// Filter with the same pika_report_authorize() the individual reports use
// rather than a second permission scheme, then hand the surviving entries to
// the identical 'ul' plugin htmlReportList() uses, so the markup and the
// report_list element id are unchanged. reportList() keys the array by report
// directory name, which is exactly the value stored in groups.reports.
//
// htmlReportList() itself is left alone: it also feeds site_map.php and the
// sidebar on other pages, and that shared helper is not in scope here.
$all_reports = pikaMisc::reportList(true, true);
$allowed_reports = array();

foreach ($all_reports as $report_dir => $report_html)
{
	if (pika_report_authorize($report_dir))
	{
		$allowed_reports[$report_dir] = $report_html;
	}
}

if (empty($allowed_reports))
{
	$C .= '<p>You are not authorized to run any reports. '
		. 'Contact your administrator if you need access.</p>';
}
else
{
	$C .= "<p>Available reports:</p>";
	$C .= pikaTempLib::plugin('ul', 'report_list', 'report_list', $allowed_reports);
}

$main_html['page_title'] = "Reports";
$main_html['content'] = $C;
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; <a href=\"{$base_url}/reports/\">Reports</a> &gt; Report Listing";

$buffer = pl_template($main_html, 'templates/default.html');
pika_exit($buffer);

?>
