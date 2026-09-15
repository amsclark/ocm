<?php

/***************************/
/* Pika CMS (C) 2011       */
/* Pika Software, LLC.     */
/* http://pikasoftware.com */
/***************************/

require_once('pika-danio.php');

pika_init();

require_once('plFlexList.php');
require_once('pikaTempLib.php');
require_once('pikaCase.php');
require_once('pikaTransferOption.php');

// Variables

$main_html = $html = array();  // Template values.

/*	transfer_option_id and case_id name int columns, so ask pl_grab_get() for a
	number and let anything else arrive as null.

	Both values are printed back into the page: case_id lands inside the
	href="..." of the breadcrumb below and inside two value="..." attributes
	in subtemplates/transfer.html. pl_clean_form_input() encodes < and > but
	leaves quotes alone, and pl_template_sub() substitutes the value as it
	stands, so a quote in either value used to close the attribute early and
	the rest of the parameter became markup - an event handler such as
	autofocus onfocus= needs no tag of its own and no click from the user.
	A numeric case_id also cannot end the attribute.

	MySQL compares an int column against a string by reading the leading
	digits, so '408" onfocus=...' selected case 408 and the page rendered
	with the payload in it. Filtering the input is what stops that, not the
	lookup.
*/
$transfer_option_id = pl_grab_get('transfer_option_id', null, 'number');
$case_id = pl_grab_get('case_id', null, 'number');
$action = pl_grab_get('action');
$base_url = pl_settings_get('base_url');

$case_number = 'No Case #';

/*	ENFORCE PERMISSIONS

	This page had no authorization check of any kind. It took a case_id from
	the query string and printed that case's number into the breadcrumb and
	into the two value="..." attributes of subtemplates/transfer.html, so a
	user whose group holds no flags at all could read the number of any case
	in the system by asking for its id here -- while case.php answered the
	same id with a 403. It also listed every configured transfer destination
	to whoever loaded it. CWE-862.

	The predicate is the one the handler already applies:
	ops/transfer_case.php refuses unless pika_authorize('edit_case', ...) on
	the case being transferred. Using the same one here means nobody who
	could actually complete a transfer loses the page, and the form stops
	being drawn for people the handler would refuse anyway.

	A request that names no case is refused too. Every link into this page
	carries a case_id -- the button in subtemplates/case_screen.html and the
	hidden field in the form in subtemplates/transfer.html -- and the handler
	refuses a request without one, so there is nothing to serve.

	The old code also explains why the lookup is guarded rather than
	unconditional: pikaCase's constructor treats a null id as a NEW case, and
	a new case draws the next value from the 'case_number' counter straight
	away and leaves it drawn, because nothing here saves the case. Loading
	this page without a case used to consume a case number every time.
*/
if (is_null($case_id))
{
	pl_case_not_viewable($base_url);
}

/*	Confirm the row is there before constructing pikaCase. plBase's
	constructor answers a missing row with trigger_error(), and
	pl_error_handler() turns that into the generic error page and
	pika_exit()s -- so `new pikaCase($absent_id)` never returns and a check
	made after it can never run. Same guard as cms/ops/upload_document.php.
*/
$case_exists = false;
$result = DB::query(
	"SELECT case_id FROM cases WHERE case_id = '"
	. DB::escapeString((string) (int) $case_id) . "' LIMIT 1"
);

if ($result && DBResult::numRows($result) > 0)
{
	$case_exists = true;
}

if (!$case_exists)
{
	pl_case_not_viewable($base_url);
}

$case = new pikaCase($case_id);

/*	Read the row through getValues() rather than testing the magic property:
	plBase exposes columns through __get() but defines no __isset(), so
	empty()/isset() on one is always true whatever the loaded value is.
*/
$case_row = $case->getValues();

if (!is_array($case_row) || empty($case_row['case_id']))
{
	pl_case_not_viewable($base_url);
}

if (!pika_authorize('edit_case', $case_row))
{
	pl_case_not_viewable($base_url);
}

if (strlen((string) $case->number) > 0)
{
	$case_number = $case->number;
}

/*	A case number is a stored value that a user types, and every use of it
	below is HTML: the breadcrumb link text and the %%[case_number]%% tag in
	both sections of subtemplates/transfer.html. Escape it once here rather
	than at each of the four sinks.
*/
$case_number = pl_html_escape($case_number);

$html['case_id'] = $case_id;
$html['case_number'] = $case_number;


switch ($action) {
	case 'pika':
		$transfer_opt = new pikaTransferOption($transfer_option_id);
		$html = array_merge($html, $transfer_opt->getValues());
		/*	The agency label is printed twice in the pika_menu section, both
			times as text. plFlexList::addRow() escapes the copy the list
			below draws, but the values handed straight to pikaTempLib are
			not escaped for us.
		*/
		$html['label'] = pl_html_escape($html['label']);
		$template = new pikaTempLib('subtemplates/transfer.html', $html, 'pika_menu');
		$main_html['content'] = $template->draw();
		break;
	default:
		$menu_transfer_mode = pl_menu_get('transfer_mode');
		$option_list = new plFlexList();
		$option_list->template_file = 'subtemplates/transfer.html';
		$pikaTransferOption = new pikaTransferOption();
    	$result = $pikaTransferOption->getTransferOptionDB();
		//$result = pikaTransferOption::getTransferOptionDB();
		while ($row = DBResult::fetchRow($result)) {
			$row['case_id'] = $case_id;
			$row['case_number'] = $case_number;
			// TODO - Need to find a better way to do this - perhaps the menu_transfer_mode
			//        values should be the action names.
			if($row['transfer_mode'] == 1) { // Pika->Pika
				$row['action'] = 'pika';
			}
			$row['transfer_mode'] = pl_array_lookup($row['transfer_mode'],$menu_transfer_mode);
			$option_list->addRow($row);
		}
		$html['option_list'] = $option_list->draw();
		$template = new pikaTempLib('subtemplates/transfer.html',$html,'main_menu');
		$main_html['content'] = $template->draw();
		break;
}


$main_html['page_title'] = $page_title = "Case Transfer";
$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt; 
					<a href=\"{$base_url}/case.php?case_id={$case_id}\">{$case_number}</a> &gt; 
					{$page_title}";

$default_template = new pikaTempLib('templates/default.html', $main_html);
$buffer = $default_template->draw();

pika_exit($buffer);

?>
