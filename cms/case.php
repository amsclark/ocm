<?php
// 08-19-2011 - AMW - inserted change to support email link
/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

/* These screens display case information. */
require_once('pika-danio.php');
pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

require_once('pikaCase.php');
require_once('pikaMisc.php');
require_once('pikaTempLib.php');
require_once('pikaCaseTab.php');
require_once('pikaScreen.php');


// TODO - deprecate this when the case_screen module is revamped for PHP 5.
function pl_warning($str)
{
	return pikaMisc::htmlRedFlag($str);
}


// VARIABLES
$main_html = array();  // Values for the main HTML template.
$base_url = pl_settings_get('base_url');
$warnings = '';  // HTML text for the red flags.
$screen = pl_grab_get('screen', 'act');

/*	$clean_screen names a file this page include()s, so it is held to a list
	of allowed characters instead of a list of forbidden ones.
	pl_clean_file_name() only drops ';', '/' and '..', which leaves NUL
	bytes, backslashes and everything else in place.
*/
$clean_screen = preg_replace('/[^A-Za-z0-9_-]/', '', (string) $screen);
if (strlen($clean_screen) < 1)
{
	$clean_screen = 'act';
}

/*	'number' mode only asks is_numeric(), which says yes to 1.5, 1e3 and -1.
	None of those is a primary key, and MySQL reads the leading digits of a
	string when it compares one against an int column.
*/
$case_id = filter_var(pl_grab_get('case_id', null, 'number'), FILTER_VALIDATE_INT, array('options' => array('min_range' => 1)));
if ($case_id === false)
{
	$case_id = null;
}

// BEGIN MAIN CODE...

// first off, make sure there's a case_id
if (is_null($case_id))
{
	header("Location: {$base_url}/cal_week.php");
	exit();
}

/* Get case record data (it'll be needed on every page is some form), store in $case_row. */
$case1 = new pikaCase($case_id);
$case_row = $case1->getValues();

/*	ENFORCE PERMISSIONS
	
	This gate used to sit further down, after the primary client record was
	loaded. That load calls makeClientDataSnapshot() and $case1->save(), so
	a request for a case the caller cannot read still wrote to the database
	and still ran every query below. It runs here now, on the case row and
	nothing else.
*/
if (!pika_authorize('read_case', $case_row))
{
	http_response_code(403);
	$main_html['page_title'] = 'Case';
	$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; <a href=\"{$base_url}/case_list.php/\">Cases</a>";
	$main_html['content'] = "This case is not viewable.";
	$default_template = new pikaTempLib('templates/default.html',$main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}

if (is_numeric($case1->getValue('client_id')))
{
	/* AMW 2017-02-10 - A missing contact record is rare but happens often enough
	that we	should check for it	and handle it gracefully if it occurs. */
	
	$clean_client_id = DB::escapeString($case1->getValue('client_id'));
	$resultc = DB::query("SELECT contact_id FROM contacts WHERE contact_id = 
	{$clean_client_id}");
	
	if (DBResult::numRows($resultc) == 1)
	{
	require_once('pikaContact.php');
	
	$primary_client = new pikaContact($case1->getValue('client_id'));
	$case1->makeClientDataSnapshot($primary_client);
	$case_row = array_merge($case_row, $primary_client->getValues());
	
	if(!isset($case_row['client_age']) || !$case_row['client_age'])
	{
		$client_age = $primary_client->calcAge($primary_client->birth_date,$case_row['open_date']);
		if($client_age && is_numeric($client_age))
		{
			$case1->client_age = $case_row['client_age'] = $client_age;
			$case1->save();
		}
	}
	
	$case_row['client_name'] = pl_text_name($case_row);
	$case_row['client_phone'] = pl_text_phone($case_row);
	$case_row['birth_date'] = pl_date_unmogrify($case_row['birth_date']);
}	
}	

// Prevent JS insertion attacks.
$case_row = pl_clean_html_array($case_row);

// Do this after HTML tags are stripped out so the line break is preserved.
if (is_numeric($case1->getValue('client_id')))
{
	$case_row['client_address'] = nl2br(pl_text_address($case_row));
}

// PAGE HEADING
if ($case_row['number'])
{
	$num = $case_row['number'];
}

else
{
	$num = '(no case #)';
}


// Determine if the user is allowed to edit this case.
$allow_edits = pika_authorize('edit_case', $case_row);
$readonly = '';
if (!$allow_edits)
{
	$readonly = '*READ ONLY*';
}

$main_html['page_title'] = "Case # {$num}";
$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; <a href=\"{$base_url}/case_list.php/\">Cases</a> &gt; {$num} {$readonly}";


// (read_case is enforced above, before any case data is loaded.)

if ('confirm_delete' == $clean_screen) 
{
	/*	The delete confirmation screen used to open to anybody who could read
		the case, keyed on the raw $screen. ops/delete_case.php does check
		delete_case, so this is the screen catching up with the operation it
		leads to - and it asks the same question that handler asks, not a
		weaker one.
	*/
	if (!pika_authorize('delete_case', $case_row))
	{
		http_response_code(403);
		$main_html['content'] = "You do not have permission to delete this case.";
		$default_template = new pikaTempLib('templates/default.html',$main_html);
		$buffer = $default_template->draw();
		pika_exit($buffer);
	}
	
	$template = new pikaTempLib('subtemplates/case_delete.html', $case_row);
	$main_html['content'] = $template->draw();
	$default_template = new pikaTempLib('templates/default.html',$main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}

// AMW - Begin of LSC 2008 CSR section.
//ini_set('display_errors', 'On');
$current_year = date('Y');
$current_datetime = date('U');
$cutoff_datetime = '1207022340';

$year_opened = substr($case_row['open_date'], 0, 4);
$year_closed = substr($case_row['close_date'], 0, 4);

/*
The following if clause chooses whether to use the 2007 or the 2008 closing and 
problem codes based on the case's open and closed dates.  TODO:  After March 2009
 it should revert back to the regular old closing and problem code menus.  The
2008 menu tables can be discarded and the 2007 menu tables can be kept around
for historical reporting purposes if desired.

Cases that are closed in 2007 or earlier will use the 2007 codes.  Cases that are
closed in 2008 or later will use the 2008 codes.
Cases that haven't been closed are more complicated.  If they were opened in 2008 or
later, they will use 2008 codes.  If not, they will use 2007 codes until March 31st,
after which they will change to the 2008 codes.
*/

if ($year_opened >= 2008)
{
	// Use 2008 codes.
	$m1 = pl_menu_get('problem_2008');
	$case_row['lsc_problem_text'] = pl_array_lookup($case_row['problem'],$m1);
} else if ($year_closed < 2008 ||
	(strlen($case_row['close_date']) == 0 && $year_opened < 2008 && $current_datetime < $cutoff_datetime))
{
	// Use 2007 codes.
	$m1 = pl_menu_get('problem_2007');
	$case_row['lsc_problem_text'] = pl_array_lookup($case_row['problem'],$m1);
} else {
	// Use 2008 codes.
	$m1 = pl_menu_get('problem_2008');
    $case_row['lsc_problem_text'] = pl_array_lookup($case_row['problem'],$m1);
}

// AMW - End of LSC 2008 CSR.


// CASE CONTACTS LISTING	
$clients = array();
$opposings = array();
$others = array();

$clients_html = '';
$opposings_html = '';
$others_html = '';

$primary_html = '';
$contacts_html = '';

// get contacts info to complement the $caserow array
$result = $case1->getContactsDb();
while ($row = DBResult::fetchRow($result))
{
	$contact_ids[] = $row['contact_id'];
	$clean_contact_name = addslashes($row['last_name']) . ', ' . addslashes($row['first_name']);
	
	/*	Kept unescaped for the two JavaScript values below, which are encoded
		for JavaScript rather than for HTML.
	*/
	$dirty_row = $row;
	
	$row['full_name'] = pl_text_name($row);
	$row['full_phone'] = pl_text_phone($row);
	
	// Begin custom template variable for client.
	$row['cnp_info_js'] = $row['full_name'] . "\n";

	if (strlen(trim(pl_text_address($row))) > 0)
	{
	  $row['cnp_info_js'] .= trim(pl_text_address($row)) . "\n";
	}

	if (strlen(trim($row['phone'] . $row['phone_notes'])) > 0)
	{
		$ztmp = pl_text_phone($row) . ' ' . $row['phone_notes'];
	  $row['cnp_info_js'] .= trim($ztmp) . "\n";
	}
	
	if (strlen(trim($row['phone_alt'] . $row['phone_notes_alt'])) > 0)
	{
		$ytmp = array('phone' => $row['phone_alt'], 'area_code' => $row['area_code_alt']);
		$ztmp = pl_text_phone($ytmp) . ' ' . $row['phone_notes_alt'];
	  $row['cnp_info_js'] .= trim($ztmp) . "\n";
	}

	if (strlen(trim($row['email'])) > 0)
	{
	  $row['cnp_info_js'] .= trim($row['email']) . "\n";
	}
		
	/*	Every value in $row is drawn on the page by pl_template(), which
		substitutes a tag value exactly as it is given. $case_row is escaped
		above for that reason; the contact row was not, so a name, address or
		phone note held in the database went to the page as markup. Contact
		records do not all arrive through a web form - the LSXML transfer
		endpoint and the import tools write them too.
	*/
	$cnp_info_js = $row['cnp_info_js'];
	$row = pl_clean_html_array($row);
	
	//	This one lands in a JavaScript string, so it is encoded for that.
	$row['cnp_info_js'] = json_encode($cnp_info_js, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT);
	// End custom template variable for client.
	
	// NEW WAY
	if ($row['contact_id'] == $case_row['client_id'] && '1' == $row['relation_code'])
	{
		$primary_html .= pl_template('subtemplates/case_screen.html', array_merge($row, $case_row), 'client');
	}
	
	else
	{
		$row['number'] = $case_row['number'];  // Needed for contact.php link.
		$contacts_html .= pl_template('subtemplates/case_screen.html', $row, 'contacts');
	}
	
	// OLD WAY
	// If it's a client
	if ($row["relation_code"] == 1)
	{
		$clients[$row['contact_id']] = $row;
		
		if ($row['contact_id'] == $case_row['client_id'])
		{
			// Don't display the primary client; they've already been displayed.
			/*	The name goes into a JavaScript string that sits inside an
				HTML attribute, so it is encoded twice over: json_encode()
				for the string, then htmlspecialchars() for the attribute.
				Interpolated straight in, an apostrophe in a contact name
				ended the string and the rest of the name became code.
			*/
			$remove_name_js = htmlspecialchars(json_encode(pl_text_name($dirty_row), JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT), ENT_QUOTES | ENT_HTML5);
			$conflict_id_safe = (int) $row['conflict_id'];
			$case_id_safe = (int) $row['case_id'];
			$clients_html .= "<img src=\"images/point.gif\" alt=\"Arrow\"/> <a onClick=\"return confirm('Are you sure you want to remove ' + {$remove_name_js} + ' from this case?');\" href=\"dataops.php?action=delete_conflict&conflict_id={$conflict_id_safe}&case_id={$case_id_safe}\">remove</a>\n";
		}
		
		else
		{
			$clients_html .= pl_template('subtemplates/case_screen.html', $row, 'contacts');
		}
	}
	
	// If it's an opposing party...
	else if (2 == $row["relation_code"])
	{
		$opposings[$row['contact_id']] = $row;
		$opposings_html .= pl_template('subtemplates/case_screen.html', $row, 'contacts');
	}
	
	// If it's something else (Opposing Counsel, Witness, etc.)
	else
	{
		$others[] = $row;
		$others_html .= pl_template('subtemplates/case_screen.html', $row, 'contacts');
	}
}
	
// NEW WAY
$case_row['client'] = $primary_html;
$case_row['contacts'] = $contacts_html;

if ($case1->unread_sms > 0)
{
	/*	"{$base_url}\case.php" put a literal backslash in the URL, so this
		link has never worked.
	*/
	$sms_case_id = (int) $case1->case_id;
	$sms_unread = (int) $case1->unread_sms;
	$case_row['client'] = "<p><a href=\"{$base_url}/case.php?"
		. "case_id={$sms_case_id}&amp;screen=sms\"><span class=\"badge badge-info\">"
		. "{$sms_unread}</span> new SMS messages</a></p>" . $case_row['client'];
}

// OLD WAY
/*
$case_row['contacts'] = '';

if (sizeof($clients) > 1)
{
	$case_row['contacts'] .= "<h2 class=\"chdt\">Additional&nbsp;Clients</h2><p>{$clients_html}</p>\n";
}

if (sizeof($opposings) > 0)
{
	$case_row['contacts'] .= "<h2 class=\"chdt\">Opposing&nbsp;Parties</h2><p>{$opposings_html}</p>\n";
}

if (sizeof($others) > 0)
{
	$case_row['contacts'] .= "<h2 class=\"chdt\">Additional&nbsp;Parties</h2><p>{$others_html}</p>\n";
}
*/

// This is for Toledo.
if (isset($case_row['in_holding_pen']) && true == $case_row['in_holding_pen'])
{
	// set up template, then display page
	$plTemplate["page_title"] = "Case: {$num}";
	$plTemplate['nav'] = "<a href=\"{$base_url}/site_map.php\">Pika Home</a>
 	  &gt; <a href='case_list.php'>Case List</a> &gt;  $num ";

	$holding_tags = $case_row;
	
	$holding_tags['client'] = '';
	foreach ($clients as $m)
	{
		$q = pl_template('subtemplates/holding_pen_client.html', $m);
		
		$holding_tags['client'] .= $q;
	}

	$holding_tags['opposing'] = '';
	foreach ($opposings as $m)
	{
		$q = pl_template('subtemplates/holding_pen_client.html', $m);
		
		$holding_tags['opposing'] .= $q;
	}
	
	$plTemplate['content'] = pl_template('subtemplates/holding_pen.html', $holding_tags);
	
	echo pl_template($plTemplate, 'templates/default.html');
	echo pl_bench('results');
	exit();
}


// more TEMPLATE VARIABLES
/*	def_relation_code is a stored user preference, so it is validated here
	rather than trusted to be the menu key it should be.
*/
$def_relation_code = filter_var(isset($_SESSION['def_relation_code']) ? $_SESSION['def_relation_code'] : null, FILTER_VALIDATE_INT, array('options' => array('min_range' => 1)));
$case_row['relation_code'] = ($def_relation_code !== false) ? $def_relation_code : 1;

if (array_key_exists('client_id', $case_row) 
	&& !is_null($case_row['client_id'])
	&& array_key_exists($case_row['client_id'], $clients))
{
	$case_row['client_name'] = pl_text_name($clients[$case_row['client_id']]);
	$case_row['client_address'] = pl_html_address($clients[$case_row['client_id']]);
	$case_row['client_phone'] = pl_text_phone($clients[$case_row['client_id']]);
	$case_row['birth_date'] = pl_date_unmogrify($clients[$case_row['client_id']]['birth_date']);
	$case_row['phone_notes'] = pl_html_text($case_row['phone_notes']);
	$case_row['notes'] = pl_html_text($case_row['notes']);
	$case_row = array_merge($clients[$case_row['client_id']], $case_row);
}

/* Some programs may want to put little blurbs on the case screen. */
$case_row['open_date_label'] = pl_date_unmogrify($case_row['open_date']);
//$case_row['atty_label'] = pl_array_lookup($case_row['user_id'], $user_id_menu);


// CASE TAB MODULE
$C = '';  // The HTML displayed by the case tab module.

// This GARBAGE is needed for legacy case tab modules.
function pl_array_menu() {}
function pl_table_array() {}
function pika_case_heading() {}
function pika_heading() {}

$pk = new pikaMisc();
$user_id = $auth_row['user_id'];
// 2013-08-13 AMW - Removed =& for compatibility with PHP 5.3.
$clean_case_screen = $case_row;
$client = array();
$primary_client = array();
$custom_dir = pl_custom_directory() . "/";

pl_menu_set_temp('user_id', pikaMisc::fetchStaffArray());
pl_menu_set_temp('case_handlers', pikaMisc::getCaseHandlerArray($case1->getValue('user_id'), $case1->getValue('cocounsel1'), $case1->getValue('cocounsel2')));
// End GARBAGE.
/*	Use $clean_screen to look for a custom or stock tab module to include,
	otherwise give an error message. The name was reduced to
	/^[A-Za-z0-9_-]+$/ where it was read; the pattern is asserted again here
	so a later change to that line cannot quietly reach include().
*/
if (!preg_match('/^[A-Za-z0-9_-]+$/', $clean_screen))
{
	$C .= "Error:  Invalid screen mode cannot be loaded";
}
else if (file_exists("{$custom_dir}/case_tabs/{$clean_screen}/{$clean_screen}.php")){	
	include("{$custom_dir}/case_tabs/{$clean_screen}/{$clean_screen}.php");
}elseif (file_exists("{$custom_dir}/modules/case-{$clean_screen}.php")){	
	include("{$custom_dir}/modules/case-{$clean_screen}.php");
}else if (file_exists("modules/case-{$clean_screen}.php")){
	include("modules/case-{$clean_screen}.php");
}

else if (pikaScreen::exists($clean_screen))
{
	$s = new pikaScreen($clean_screen);
	$C .= $s->htmlForm($case1->getValues());
}

else
{
	//	The screen name is echoed back, so it is escaped on the way out.
	$C .= "Error:  Invalid screen mode (" . htmlspecialchars($clean_screen, ENT_QUOTES | ENT_HTML5) . ") cannot be loaded";
}


// CASE TABS

if (file_exists(pl_custom_directory() . "/extensions/case_tabs/case_tabs.php"))
{
	require_once(pl_custom_directory() . "/extensions/case_tabs/case_tabs.php");
	$menu_case_tabs = case_tabs_extension($case1);
}

else
{
	$result = pikaCaseTab::getCaseTabsDB();
	$menu_case_tabs = array();
	while($row = DBResult::fetchRow($result))
	{
		$menu_case_tabs[$row['file']] = $row;
	}
}

$custom_screens = pikaScreen::getScreens();
foreach ($custom_screens as $key => $value)
{
	$menu_case_tabs["custom-screen-{$key}"] = array('name' => $value, 'file' => "case-{$key}.php", 'enabled' => 1, 'tab_order' => 1000+$key, 'autosave' => true, 'tab_row' => 2);
}

$case_row['case_tabs'] = pikaTempLib::plugin('case_tabs',$clean_screen,$case_row,$menu_case_tabs,array('js_mode'));

// end TABS



// CASE SCREEN MODULE
if (file_exists("{$custom_dir}/modules/case_screen.php"))
{	
	include("{$custom_dir}/modules/case_screen.php");
}
else {
	include('modules/case_screen.php');
}


// RED FLAGS
if ($warnings)
{
	$case_row['flags'] = "<p>$warnings</p>\n";
}

$case_row['case_screen'] = $C;

/*	08-18-2011 - AMW - Populate the "server_url" template tag.  This is needed
	for email link.
	
	With UseCanonicalName Off, which is the Apache default, SERVER_NAME is
	taken from the request's Host header. The tag is drawn into the mailto:
	case link, so anything that is not a hostname character comes out.
*/
$server_name = isset($_SERVER['SERVER_NAME']) ? $_SERVER['SERVER_NAME'] : '';
$case_row['server_url'] = preg_replace('/[^A-Za-z0-9.\-]/', '', (string) $server_name);

$main_html['content'] = pl_template('subtemplates/case_screen.html', $case_row);
$main_html['rss'] = file_get_contents('js/form_save.js');

$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
