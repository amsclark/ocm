<?php 
/***********************************/
/* Pika CMS (C) 2009 Aaron Worley  */
/* http://pikasoftware.com         */
/*                                 */
/* Modified February 2020           */
/* By Metatheria, LLC              */ 
/* https://metatheria.solutions    */
/***********************************/


chdir('../../');

require_once('pika-danio.php'); 
pika_init();
require_once('pikaTempLib.php');
require_once('pikaMisc.php');

$report_title = "Mega Party Report";
$report_name = "megapartyreport";

$base_url = pl_settings_get('base_url');
if(!pika_report_authorize($report_name)) {
	$main_html = array();
	$main_html['base_url'] = $base_url;
	$main_html['page_title'] = $report_title;
	$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a>
    				  &gt; <a href=\"{$base_url}/reports/\">Reports</a> 
    				  &gt; $report_title";
	$main_html['content'] = "You are not authorized to run this report";

	$buffer = pl_template('templates/default.html', $main_html);
	pika_exit($buffer);
}

$menu_recordlimit = array (	'100' => '100',
							'1000' => '1,000',
							'5000' => '5,000',
							'10000' => '10,000',
							'50000' => '50,000',
							'100000' => '100,000');

$a = array();
$a['report_name'] = $report_name;
$a['recordlimit'] = '10000';
$a['fo'] = array();
$a['current_date'] = date('n/d/Y');

$main_html = array();
$reports = pikaMisc::reportList(true);
$y = "";
foreach ($reports as $z)
{
        $y .= "<li>{$z}</li>\n";
}
$main_html['report_list'] = $y;
$main_html['base_url'] = $base_url;
$main_html['page_title'] = $report_title;
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a>
      &gt; <a href=\"{$base_url}/reports/\">Reports</a> &gt; $report_title";
$template = new pikaTempLib("reports/{$report_name}/form.html",$a);
$template->addMenu('fields',array());
$template->addMenu('fo',array());
$template->addMenu('sum',array());
$template->addMenu('count',array());
$template->addMenu('recordlimit',$menu_recordlimit);
$template->addMenu('group_by',array());
$template->addMenu('order_by',array());
$main_html['content'] = $template->draw();


$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
