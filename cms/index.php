<?php

/**********************************/
/* Pika CMS (C) 2009 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('pika-danio.php');
pika_init();

/* AMW 2015-10-07 - This supresses the "Are you sure you want to resubmit this 
	form?" prompts when you log, click on a link, then hit the back button.
	Eventually I'll add a system-wide solution for this issue, in which case
	this code can then be removed. */
if(isset($_REQUEST['auth_id']) && is_numeric($_REQUEST['auth_id']))
{
	// 2013-08-22 AMW - Replaced reference to $plSettings, it was not working
	// in some test configurations.
	header("Location: " . pl_settings_get('base_url') . "/");
}

require_once('pikaMotd.php');
require_once('pikaRssFeed.php');
require_once('pikaSettings.php');
require_once('pikaMisc.php');


$main_html = array();  // Values for the main HTML template.
$home_page = array();
$messages_text = '';

// AMW - Display password expiration notice if appropriate.
// MDF - Make sure that password expiration is enabled and that negative values aren't displayed
$password_expire = pl_settings_get('password_expire');
if ($password_expire && isset($auth_row['password_expire']) && $auth_row['password_expire'] && $auth_row['password_expire'] > time())
{
	$days_remaining = round(($auth_row['password_expire'] - time()) / 86400);
	if ($days_remaining < 8)
	{
		$messages_text .= "<p><strong>Notice:  Your password expires in {$days_remaining} ";
		$messages_text .= "day(s).</strong></p>\n";
	}
}
// End AMW

$result = pikaMotd::getMotdDB();
if (DBResult::numRows($result) < 1)
{
	$messages_text .= "<blockquote><tt>Welcome to the Pika Case Management System!</tt></blockquote>\n";
}

else 
{
	while ($row = DBResult::fetchRow($result))
	{
		$motd_id = pl_clean_html($row['motd_id']);
		
		$row['staff_name'] =  pl_clean_html(pl_text_name($row));
		$row['summary_content'] = pl_html_text($row['content']);
		
		if(strlen($row['content']) > 140) 
		{
			$row['summary_content'] = pl_html_text(substr($row['content'],0,140));
			$row['summary_content'] .= " ... (<i><a href=\"#\" onclick=\"toggleMotd({$motd_id});" .
										 " return false;\">View Full Text</a></i>)";
		}
		
		$row['content'] = pl_html_text($row['content']);
		$messages_text .= pl_template('subtemplates/home.html', $row, 'motd');
	}
}
$reports = pikaMisc::reportList(true);
$y = "";
foreach ($reports as $report)
{
  /*	This said ${z}. There is no $z, so every report rendered as an empty
  	bullet: the home page listed the right NUMBER of reports and none of
  	their names or links. It also logged one "Undefined variable" warning
  	per report per page load. reportList(true) returns finished, escaped
  	<a href> markup, so $report goes in as-is.
  */
  $y .= "<li>{$report}</li>";
}
$main_html['report_list'] = $y;

$feeds_array = pikaRssFeed::getFeeds();
$feeds_text = '';
if(count($feeds_array) >= 1) 
{
	foreach ($feeds_array as $feed) {
		$feeds_text .= "<h2>" . pl_html_escape($feed['title']) . "</h2>\n";
		
		foreach ($feed['entries'] as $entry) 
		{
			/*	Everything below comes from a third party feed, and
				pl_template() substitutes a tag value as it is given. So each
				field is made safe here: the two titles are escaped, the link
				has to be a scheme a browser can follow, and the body is
				rebuilt from a parsed tree.
				
				strip_tags() used to do the body. It keeps every attribute on
				the tags it allows, so a feed could put onmouseover= on an
				allowed <a> and point its href at javascript:.
			*/
			$raw_content = $entry['content'];
			$entry['feed_id'] = rand();
			$entry['title'] = pl_html_escape($entry['title']);
			$entry['link'] = pl_html_escape(pikaRssFeed::safeUrl($entry['link']));
			$entry['content'] = pikaRssFeed::safeHtml($raw_content);
			$entry['summary_content'] = $entry['content'];
			if(strlen($raw_content) > 140) 
			{
				//	Cut the raw text and rebuild it, so the parser closes the
				//	tag the cut ran through.
				$entry['summary_content'] = pikaRssFeed::safeHtml(substr($raw_content,0,140));
				$entry['summary_content'] .= " ... (<i><a href=\"#\" onclick=\"toggleFeed({$entry['feed_id']});" .
											 " return false;\">View Full Text</a></i>)";
			}
			$feeds_text .= pl_template('subtemplates/home.html',$entry,'rss_feeds');
		}
	}
}

$reports = pikaMisc::reportList(true);
$y = "";

foreach ($reports as $z)
{
	$y .= "<li>{$z}</li>\n";
}

$home_page['report_list'] = $y;

$home_page['motd'] = $messages_text;
$home_page['rss_feeds'] = $feeds_text;
$home_page['user_id'] = $auth_row['user_id'];


$main_html['page_title'] = "Home Page";
$main_html['content'] = pl_template('subtemplates/home.html', $home_page);
$main_html['nav'] = "Pika Home";

$buffer = pl_template($main_html, 'templates/default.html');
pika_exit($buffer);

?>
