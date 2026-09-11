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


/*	Answer a request for a case this user may not see, and say nothing else.

	Used for both a case_id that does not exist and a case_id the caller is
	not authorized to read, so the two are indistinguishable.
*/
function pl_case_not_viewable($base_url)
{
	$main_html = array();
	$main_html['page_title'] = 'Case';
	$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a> &gt; <a href=\"{$base_url}/case_list.php/\">Cases</a>";
	$main_html['content'] = "This case is not viewable.";
	$default_template = new pikaTempLib('templates/default.html', $main_html);
	pika_exit($default_template->draw());
}


// VARIABLES
$main_html = array();  // Values for the main HTML template.
$base_url = pl_settings_get('base_url');
$warnings = '';  // HTML text for the red flags.
$screen = pl_grab_get('screen', 'act');

/*	The three include() calls near the bottom of this file build their target
	out of $clean_screen, and pl_clean_file_name() is a blocklist: it drops ';',
	'/' and one pass of '..' and passes everything else through, including a
	backslash, a null byte and a leading dot. Every stock and custom tab module
	is named with letters, digits, underscore and dash, so use that as an
	allowlist and fall back to the default tab for anything else.
*/
$clean_screen = preg_match('/^[A-Za-z0-9_-]+$/', (string) $screen) ? $screen : 'act';

/*	is_numeric() - the old test, a few lines down - accepts '1e3', '12.0',
	'+12' and ' 12', all of which then reached SQL through pikaCase. Ask for an
	integer and refuse anything that is not one.
*/
$case_id = filter_var(pl_grab_get('case_id', null, 'number'), FILTER_VALIDATE_INT,
	array('options' => array('min_range' => 1)));

// BEGIN MAIN CODE...

// first off, make sure there's a case_id
if (false === $case_id)
{
	header("Location: {$base_url}/cal_week.php");
	exit();
}

/*	Ask whether the case exists before loading it.

	plBase::__construct() answers a SELECT that returns no row with
	trigger_error("... No such record found."), and the pl error handler turns
	that into the generic "This page is currently unavailable" screen and
	exits. That screen looks nothing like the "This case is not viewable"
	refusal below, so a user could walk case_id values and tell which numbers
	are real cases they may not read from which are not cases at all. Answer
	both the same way. $case_id passed FILTER_VALIDATE_INT above.
*/
$case_exists = DB::query("SELECT case_id FROM cases WHERE case_id = "
	. (int) $case_id . " LIMIT 1");

if (!$case_exists || DBResult::numRows($case_exists) < 1)
{
	pl_case_not_viewable($base_url);
}

/* Get case record data (it'll be needed on every page is some form), store in $case_row. */
$case1 = new pikaCase($case_id);
$case_row = $case1->getValues();

/*	ENFORCE PERMISSIONS - moved up from below the client-record load.
	
	Two things used to happen before this check. The primary client's contact
	row was read, and when the case had no cached client_age the case row was
	UPDATEd with one. Both ran for a caller who was then told the case is not
	viewable, so an unauthorized request read a client record and wrote to a
	case it may not see.
	
	The heading and breadcrumb are also built after this point now. They used
	to be built first and carried the case number, so the "not viewable" page
	handed the number of the case to the user who was being refused it.
*/
if (!pika_authorize('read_case', $case_row))
{
	pl_case_not_viewable($base_url);
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


/*	The delete confirmation screen opened for anyone who could read the case.
	ops/delete_case.php requires the 'delete_case' permission, which in this
	application means the 'system' group, so every other user was shown a form
	whose only possible outcome is a refusal - and the subtemplate it draws
	carries case data onto a screen that user has no business on. Ask for the
	same permission the delete itself asks for.
*/
if ('confirm_delete' == $clean_screen)
{
	if (!pika_authorize('delete_case', $case_row))
	{
		$main_html['content'] = "You are not authorized to delete this case.";
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

	// A contact with no e-mail address holds NULL here, not ''.
	if (strlen(trim((string) $row['email'])) > 0)
	{
	  $row['cnp_info_js'] .= trim($row['email']) . "\n";
	}
		
	/*	No stock template reads %%[cnp_info_js]%%, but a per-org overlay copy of
		case_screen.html can, and the tag lands inside a script block. Plain
		json_encode() leaves '<', '&' and both quote characters as themselves,
		so hex-encode them: the value is then safe in a script block and inside
		an attribute.
	*/
	$row['cnp_info_js'] = json_encode($row['cnp_info_js'],
		JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT);
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
			/*	The contact's name went straight into a JS string literal
				inside an onClick attribute. pl_grab_post() does not escape
				quotes, so a name holding an apostrophe closed the literal and
				the rest of it ran as script for every user who opened the
				case. Build the literal with json_encode, then escape the
				attribute, and URL-encode the two ids in the href.
				
				Nothing prints $clients_html today: the block that used to do
				it is the commented-out "OLD WAY" further down. So this
				corrects a sink that is assembled and not yet rendered rather
				than closing a live hole.
			*/
			$confirm_js = 'return confirm(' . json_encode(
				'Are you sure you want to remove ' . pl_text_name($row) . ' from this case?',
				JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT) . ');';
			
			$clients_html .= "<img src=\"images/point.gif\" alt=\"Arrow\"/> "
				. "<a onClick=\"" . pl_html_escape($confirm_js) . "\" "
				. "href=\"dataops.php?action=delete_conflict"
				. "&conflict_id=" . urlencode($row['conflict_id'])
				. "&case_id=" . urlencode($row['case_id']) . "\">remove</a>\n";
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
	/*	The path separator here was a backslash, which PHP keeps as a literal
		backslash in a double-quoted string, so the "new SMS messages" link
		pointed at "<base_url>\case.php" and did not resolve.
	*/
	$case_row['client'] = "<p><a href=\"{$base_url}/case.php?"
		. "case_id=" . (int) $case1->case_id . "&screen=sms\"><span class=\"badge badge-info\">"
		. (int) $case1->unread_sms . "</span> new SMS messages</a></p>" . $case_row['client'];
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
/*	This lands in a menu plugin's selected-value comparison, and the session
	is written from request input elsewhere in the application, so validate it
	as the integer a relation code is rather than trusting the session.
*/
$def_relation_code = isset($_SESSION['def_relation_code'])
	? filter_var($_SESSION['def_relation_code'], FILTER_VALIDATE_INT, array('options' => array('min_range' => 1)))
	: false;

if (false !== $def_relation_code) {
	$case_row['relation_code'] = $def_relation_code;
}
else {
	$case_row['relation_code'] = 1;	
}

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
/*	Use $screen to look for a custom or stock tab module to include, otherwise 
	give an error message.
	Remove any naughty control characters before attempting to include the file.
*/
/*	Belt and braces: $clean_screen was allowlisted where it was assigned and
	is not written to in between, but these four lines are the ones that put it
	in a path, so check it here too.
*/
if (!preg_match('/^[A-Za-z0-9_-]+$/', (string) $clean_screen))
{
	$clean_screen = 'act';
}

if (file_exists("{$custom_dir}/case_tabs/{$clean_screen}/{$clean_screen}.php")){	
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
	$C .= "Error:  Invalid screen mode (" . pl_html_escape($clean_screen) . ") cannot be loaded";
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

// $clean_screen, not $screen: one validated value decides which tab is current.
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

// 08-18-2011 - AMW - Populate the "server_url" template tag.  This is needed for email link.
/*	SERVER_NAME is taken from the request's Host header when Apache runs with
	UseCanonicalName Off, which is the default, and subtemplates/case_screen.html
	substitutes this tag raw into an href. Apache's own Host parsing refuses
	anything that is not a valid host name, so the shipped container will not
	pass markup through here - but a permissive front end in front of PHP would.
	Keep only the characters a host name (or a bracketed IPv6 literal, or a
	port) may contain.
*/
$case_row['server_url'] = preg_replace('/[^A-Za-z0-9.:\[\]_-]/', '',
	(string) (isset($_SERVER['SERVER_NAME']) ? $_SERVER['SERVER_NAME'] : ''));

$main_html['content'] = pl_template('subtemplates/case_screen.html', $case_row);
$main_html['rss'] = file_get_contents('js/form_save.js');

$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
