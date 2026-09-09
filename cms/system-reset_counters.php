<?php

/************************************/
/* Pika CMS (C) 2008 Aaron Worley   */
/* http://pikasoftware.com          */
/************************************/

require_once('pika-danio.php');
pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

require_once('pikaTempLib.php');
require_once('plFlexList.php');
require_once('pikaCounter.php');


$action = pl_grab_post('action');
$base_url = pl_settings_get('base_url');

$main_html = array();
$main_html['content'] = '';

if (!pika_authorize("system", array()))
{
	$temp["content"] = "Access denied";
	$temp["nav"] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
					 <a href=\"site_map.php\">Site Map</a> &gt;
					 Reset Counters";
	
	$default_template = new pikaTempLib('templates/default.html',$temp);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}

switch ($action) {
	case 'reset':
		$main_html['content'] = pikaTempLib::plugin('red_flag','reset',"Counters have been reset");
		pikaCounter::resetCounters();
	default:
		
		$counters_list = new plFlexList();
		$counters_list->template_file = 'subtemplates/system-reset_counters.html';
		
		
		$max_counters = pikaCounter::getCurrentCounters();
		foreach ($max_counters as $counter) {
			$row['id'] = $counter['id'];
			$row['count'] = $counter['count'];
			$row['max_count'] = "N/A";
			if(isset($counter['max_count']) && is_numeric($counter['max_count'])) {
				$row['max_count'] = $counter['max_count'];
			} 
			$counters_list->addRow($row);
		}
		$a['counters_list'] = $counters_list->draw();
		$a['action'] = 'reset';
		$template = new pikaTempLib('subtemplates/system-reset_counters.html',$a);
		$main_html['content'] .= $template->draw(); 
		
		break;
		
}






// Display a screen

$main_html['page_title'] = "Reset Counters";
$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
					 <a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
					 Reset Counters";


$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
