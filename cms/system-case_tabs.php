<?php 

/**********************************/
/* Pika CMS (C) 2009 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/


require_once ('pika-danio.php');
pika_init();

// This page performs its state changes on a GET: the action is dispatched
// out of the query string and the links that trigger it are plain <a href>
// markup, so a hidden token field is not available as a defence here.
// On a non-POST request pl_csrf_check() falls through to the same-site
// check, which refuses a mutation that a foreign page initiated and needs
// nothing from the markup. See pl_request_cross_site_verdict() in pl.php.
pl_csrf_check();

require_once('plFlexList.php');
require_once('pikaCaseTab.php');
require_once('pikaTempLib.php');

pl_menu_get('yes_no');

$action = pl_grab_get('action');
$tab_id = pl_grab_get('tab_id');
$enabled = pl_grab_get('enabled');
$autosave = pl_grab_get('autosave');
$tab_order = pl_grab_get('tab_order');
$tab_row = pl_grab_get('tab_row');
$name = pl_grab_get('name');
$file = pl_grab_get('file');
$cancel = pl_grab_get('cancel');
$screen = pl_grab_get('screen');

$base_url = pl_settings_get('base_url');
$page_title = "System Case Tabs";

$menu_yes_no = array('1' => 'Yes', '0' => 'No', '' => 'No');

$buffer = '';


if (!pika_authorize("system", array()))
{
	$main_html['content'] = "Access denied";
	$main_html['page_title'] = $page_title;
	$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
						 <a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
						 {$page_title}";
	
	$default_template = new pikaTempLib('templates/default.html', $main_html);
	$buffer = $default_template->draw();
	
	pika_exit($buffer);
}


/*	Draw a short message on this page and stop.
	
	Used for the requests that name a case tab that is not there and for a
	tab file that is not installed - both of which used to end in a row of
	rubbish in the table or in a page that returned nothing at all.
*/
function case_tab_error($message)
{
	global $base_url, $page_title;
	
	$main_html = array();
	$main_html['content'] = '<p>' . pl_html_escape($message) . '</p>
		<p><a href="' . pl_html_escape($base_url) . '/system-case_tabs.php">Back to ' .
		pl_html_escape($page_title) . '</a></p>';
	$main_html['page_title'] = $page_title;
	$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
						 <a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
						 <a href=\"{$base_url}/system-case_tabs.php\">{$page_title}</a>";
	
	$default_template = new pikaTempLib('templates/default.html', $main_html);
	
	pika_exit($default_template->draw());
}


/*	Is there a case tab with this id?
	
	plBase reads a non-numeric id as "this is a new record", so an update or
	a move that arrived without a tab_id used to build a fresh object and
	write it, which left an empty tab in the list. A numeric id with no row
	behind it makes the plBase constructor trigger_error() instead, and the
	object it hands back is not usable.
*/
function case_tab_exists($tab_id)
{
	if (!is_numeric($tab_id))
	{
		return false;
	}
	
	$safe_tab_id = DB::escapeString($tab_id);
	$sql = "SELECT tab_id FROM case_tabs WHERE tab_id = '{$safe_tab_id}' LIMIT 1";
	$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
	
	return DBResult::numRows($result) == 1;
}


/*	The tab file names a module on disk.
	
	template_plugins/case_tabs.php puts this value into a link and into a
	JavaScript string on every case screen, and case.php shows a tab that
	points at a file that is not installed as a dead link. The edit form
	offers the installed modules in a menu, so anything else reached this
	page as a hand-written query string.
*/
function case_tab_file_is_installed($file)
{
	$menu_tab_files = pikaCaseTab::getCaseTabFiles();
	
	return isset($menu_tab_files[$file]);
}


/*	These actions all work on a row that is already there.
*/
$row_actions = array('update', 'enable', 'move_up', 'move_down', 'confirm_delete', 'delete');

if (in_array($action, $row_actions, true) && !case_tab_exists($tab_id))
{
	case_tab_error("That case tab is no longer there.");
}


switch ($action)
{
	case 'edit':
		/*	"Add New Case Tab" reaches this branch with no tab_id, so the
			object comes back new. It used to be save()d right here, which
			wrote an empty row on every load of the form: the tab list
			filled with blank entries, and where the counters row had
			fallen behind the real MAX(tab_id) the INSERT hit a duplicate
			key and the page came back empty.
			
			Draw the form and let the "add" action below write the row
			once, when the form is sent.
		*/
		$is_new = !case_tab_exists($tab_id);
		$tab = new pikaCaseTab($is_new ? null : $tab_id);
		$menu_tab_files = pikaCaseTab::getCaseTabFiles();
		$a = $tab->getValues();
		$a['base_url'] = $base_url;
		
		if ($is_new)
		{
			/*	There is no row yet, so the form must not carry an id -
				the "add" action allocates one when it writes.
			*/
			$a['tab_id'] = '';
			$a['action'] = 'add';
			$nav_leaf = 'New Case Tab';
		}
		else
		{
			$a['action'] = 'update';
			
			/*	The tab name went into the page as it came out of the
				table. pl_clean_html() rather than pl_html_escape(): the
				name was written through pl_grab_get(), which has already
				turned < and > into entities, so escaping again would show
				the user "&lt;" where they typed "<".
			*/
			$nav_leaf = 'Editing ' . pl_clean_html($a['name']);
		}
		
		$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
			<a href=\"{$base_url}/site_map.php\">Site Map</a> &gt; 
			<a href=\"{$base_url}/system-case_tabs.php\">$page_title</a> &gt; 
			{$nav_leaf}";
		$template = new pikaTempLib('subtemplates/system-case_tabs.html',$a,'edit_tab');
		$template->addMenu('tab_file',$menu_tab_files);
		$template->addMenu('tab_row',array('1'=>'1st Row','2' => '2nd Row'));
		$main_html['content'] = $template->draw();
		break;
	case 'add':
		/*	The one write for a new tab. This is what the "edit" branch
			used to do on a GET of the empty form.
		*/
		if (!case_tab_file_is_installed($file))
		{
			case_tab_error("Pick a tab file that is installed.");
		}
		
		$tab = new pikaCaseTab();
		$tab->name = $name;
		$tab->file = $file;
		$tab->enabled = $enabled;
		$tab->tab_row = $tab_row;
		$tab->autosave = $autosave;
		$tab->save();
		header("Location: {$base_url}/system-case_tabs.php");
		break;
	case 'update':
		if (!case_tab_file_is_installed($file))
		{
			case_tab_error("Pick a tab file that is installed.");
		}
		
		$tab = new pikaCaseTab($tab_id);
		$tab->name = $name;
		$tab->file = $file;
		$tab->enabled = $enabled;
		$tab->tab_row = $tab_row;
		$tab->autosave = $autosave;
		$tab->save();
		header("Location: {$base_url}/system-case_tabs.php");
		break;
	case 'enable':
		$tab = new pikaCaseTab($tab_id);
		if($tab->enabled == 1) {$tab->enabled = 0; }
		else {$tab->enabled = 1; }
		$tab->save();
		header("Location: {$base_url}/system-case_tabs.php");
		break;
	case 'move_up':
		$tab = new pikaCaseTab($tab_id);
		$tab->move_up();
		$tab->save();
		header("Location: {$base_url}/system-case_tabs.php");
		break;
	case 'move_down':
		$tab = new pikaCaseTab($tab_id);
		$tab->move_down();
		$tab->save();
		header("Location: {$base_url}/system-case_tabs.php");
		break;
	case 'confirm_delete':
		$tab = new pikaCaseTab($tab_id);
		$a = $tab->getValues();
		$a['action'] = 'delete';
		$delete_leaf = pl_clean_html($a['name']);
		$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
			<a href=\"{$base_url}/site_map.php\">Site Map</a> &gt; 
			<a href=\"{$base_url}/system-case_tabs.php\">$page_title</a> &gt; 
			Delete&nbsp;{$delete_leaf}";
		$template = new pikaTempLib('subtemplates/system-case_tabs.html',$a,'confirm_delete');
		$main_html['content'] = $template->draw();
		break;
	case 'delete':
		if(!$cancel) {
			$tab = new pikaCaseTab($tab_id);
			$tab->delete();
		}
		header("Location: {$base_url}/system-case_tabs.php");
		break;
	default:
		$a = array();
		$a['base_url'] = $base_url;
		$tab_list = new plFlexList();
		$tab_list->template_file = 'subtemplates/system-case_tabs.html';
		
		$result = pikaCaseTab::getCaseTabsDB();
		$case_tabs = array();
		while ($row = DBResult::fetchRow($result))
		{	
			$case_tabs[$row['tab_id']] = $row;
			$row['enable_text'] = 'Enable';
			if($row['enabled'] == 1) {
				$row['enable_text'] = 'Disable';
			}
			$row['enabled'] = pl_array_lookup($row['enabled'],$menu_yes_no);
			$row['autosave'] = pl_array_lookup($row['autosave'],$menu_yes_no);
			
			$tab_list->addRow($row);
		}
		if(!$screen) {$screen = 'info';}
		$a['tab_list'] = $tab_list->draw();
		$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
							 <a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
							 {$page_title}";
		$template = new pikaTempLib('subtemplates/system-case_tabs.html',$a,'view_tabs');
		$main_html['content'] = $template->draw();
		break;
}


$main_html['page_title'] = $page_title;
$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
