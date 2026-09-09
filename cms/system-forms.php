<?php 

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.net        */
/**********************************/


require_once('pika-danio.php');

pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

require_once('plFlexList.php');
require_once('pikaTempLib.php');
require_once('pikaDocument.php');


// FUNCTIONS


$main_html = $html = array();


$action = pl_grab_post('doc_upload');
$screen = pl_grab_post('description');
$user_id = pl_grab_post('doc_path');
$base_url = pl_settings_get('base_url');

$main_html['page_title'] = 'Form Letter Manager';


if (!pika_authorize("system", array()))
{
	$main_html["content"] = "Access denied";
	$main_html["nav"] = "<a href=\"{$base_url}\">Pika Home</a> &gt; {$main_html['page title']}";

	$default_template = new pikaTempLib('templates/default.html',$main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}


$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt; {$main_html['page_title']}";
$template = new pikaTempLib('subtemplates/system-forms.html', $html);
$main_html['content'] = $template->draw();

$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
