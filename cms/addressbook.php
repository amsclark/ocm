<?php 

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('pika-danio.php');
pika_init();

require_once('pikaMisc.php');

$main_html = array();  // Values for the main HTML template.
$base_url = pl_settings_get('base_url');
$content_t = pikaMisc::htmlContactList();

$main_html['content'] = pl_template('subtemplates/contact_list.html', $content_t);
$main_html['page_title'] = "Address Book";
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> <span class=\"nav-arrow\">&#10140;</span> Address Book";

$buffer = pl_template('templates/default.html', $main_html);
pika_exit($buffer);

?>

