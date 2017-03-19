<?php

require_once('pika-danio.php');
pika_init();

require_once('pikaMisc.php');


$main_html = array();  // Values for the main HTML template.
$content_t = array();
$extra_url = pl_simple_url();
$base_url = pl_settings_get('base_url');
$content_t = pikaMisc::htmlContactList('intake');

$main_html['content'] = pl_template('subtemplates/intake_contact_list.html', $content_t);
$main_html['page_title'] = "Case Intake";
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> <span class=\"nav-arrow\">&#10140;</span> Case Intake";

$buffer = pl_template('templates/default.html', $main_html);
pika_exit($buffer);

?>
