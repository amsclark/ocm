<?php 

/**********************************/
/* Pika CMS (C) 2006 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/


require_once('pika-danio.php');

pika_init();

// This page performs its state changes on a GET: the action is dispatched
// out of the query string and the links that trigger it are plain <a href>
// markup, so a hidden token field is not available as a defence here.
// On a non-POST request pl_csrf_check() falls through to the same-site
// check, which refuses a mutation that a foreign page initiated and needs
// nothing from the markup. See pl_request_cross_site_verdict() in pl.php.
pl_csrf_check();

require_once('pikaTempLib.php');
require_once('plFlexList.php');
require_once('pikaRssFeed.php');


// Variables

$main_html = array();  // Values for the main HTML template.
$main_html['page_title'] = $page_title = "RSS Feeds"; // Page Title
$base_url = pl_settings_get('base_url');
$action = pl_grab_get('action');
$feed_id = pl_grab_get('feed_id');

// Make sure User has system rights to change options

if (!pika_authorize("system", array()))
{
	$main_html["content"] = "Access denied";
	$main_html["nav"] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; 
						<a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
						{$main_html['page_title']}";
	
	$default_template = new pikaTempLib('templates/default.html', $main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}


// Main Code
switch ($action) {
	case 'new_feed':
		$feed = new pikaRssFeed();
		$feed_id = $feed->feed_id;
		$feed->save();
	case 'edit':
		$feed = new pikaRssFeed($feed_id);
		$row = $feed->getValues();
		
		$template = new pikaTempLib('subtemplates/system-feeds.html', $row, 'edit_feed');
		$main_html['content'] = $template->draw();
		$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; 
						<a href=\"{$base_url}/system-feeds.php\">
						{$page_title}</a> &gt;
						Edit Feed";
		break;
	case 'confirm_delete':
		$feed = new pikaRssFeed($feed_id);
		$row = $feed->getValues();
		
		$template = new pikaTempLib('subtemplates/system-feeds.html', $row, 'confirm_delete');
		$main_html['content'] = $template->draw();
		$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; 
						<a href=\"{$base_url}/system-feeds.php\">
						{$page_title}</a> &gt;
						Delete Feed";
		break;
	case 'delete':
		$feed = new pikaRssFeed($feed_id);
		$feed->delete();
		header("Location: {$base_url}/system-feeds.php");
		break;
	case 'update':
		$tmp['name'] = pl_grab_get('name');
		$tmp['feed_url'] = pl_grab_get('feed_url');
		$tmp['enabled'] = pl_grab_get('enabled');
		$tmp['list_limit'] = pl_grab_get('list_limit');
			
		$feed = new pikaRssFeed($feed_id);
		$feed->setValues($tmp);
		$feed->save();
		header("Location: {$base_url}/system-feeds.php");
		break;
	default:
		$menu_rss_type = array('1' => 'RSS','2' => 'ATOM','3' => 'RDF');
		pl_menu_set_temp('rss_type',$menu_rss_type);
		pl_menu_get('yes_no');
		$feeds_list = new plFlexList();
		$feeds_list->template_file = 'subtemplates/system-feeds.html';

		$result = pikaRssFeed::getRssDB();
		foreach ($result as $row) {
			$row['feed_type'] = pl_array_lookup($row['feed_type'],$menu_rss_type);
			$row['enabled'] = pl_array_lookup($row['enabled'],$plMenus['yes_no']);
			
			$feeds_list->addRow($row);
		}
		$a['feed_list'] = $feeds_list->draw();
		$template = new pikaTempLib('subtemplates/system-feeds.html',$a,'list_feeds');
		$main_html['content'] = $template->draw();
		$main_html["nav"] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; 
						<a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
						{$page_title}";
}


$default_template = new pikaTempLib('templates/default.html', $main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
