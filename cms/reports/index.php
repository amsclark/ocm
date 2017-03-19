<?php

chdir('../');

require_once('pika-danio.php');
pika_init();

require_once('pikaMisc.php');

$base_url = pl_settings_get('base_url');
$C = '';
$C .= "<h2 class=\"available-reports\">Available reports</h2>";
$C .= pikaMisc::htmlReportList();

$main_html['page_title'] = "Reports";
$main_html['content'] = $C;
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> <span class=\"nav-arrow\">&#10140;</span> <a href=\"{$base_url}/reports/\">Reports</a> <span class=\"nav-arrow\">&#10140;</span> Report Listing";

$buffer = pl_template($main_html, 'templates/default.html');
pika_exit($buffer);

?>
