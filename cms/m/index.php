<?php

/**********************************/
/* Pika CMS (C) 2009 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

chdir('..');

require_once('pika-danio.php');
pika_init();

require_once('pikaMotd.php');


$main_html = array();  // Values for the main HTML template.
$home_page = array();
$messages_text = '';

$result = pikaMotd::getMotdDB();
if (DBResult::numRows($result) < 1)
{
	$messages_text .= "<blockquote><tt>Welcome to the Pika Case Management System!</tt></blockquote>\n";
}

else 
{
	while ($row = DBResult::fetchRow($result))
	{
		$row['staff_name'] = pl_text_name($row);
		$row['summary_content'] = $row['content'];
		if(strlen($row['content']) > 140) 
		{
			$row['summary_content'] = pl_html_text(substr($row['content'],0,140));
			$row['summary_content'] .= " ... (<i><a href=\"#\" onclick=\"toggleMotd({$row['motd_id']});" .
										 " return false;\">View Full Text</a></i>)";
		}
		$row['content'] = pl_html_text($row['content']);
// 06-11-2010 - caw - put code here to detect mobile device				
		$messages_text .= pl_template('m/home.html', $row, 'motd');
	}
}




$home_page['motd'] = $messages_text;
$home_page['user_id'] = $auth_row['user_id'];


$main_html['page_title'] = "Home Page";
// 06-11-2010 - caw - put code here to detect mobile device
$main_html['content'] = pl_template('m/home.html', $home_page);
// end of 06-11 - caw changes

$main_html['nav'] = "Pika Home";

// 06-11-2010 - caw - put code here to detect mobile device
$buffer = pl_template($main_html, 'm/default.html');
// end of 06-11 changes
pika_exit($buffer);

?>
