<?php 

/**********************************/
/* Pika CMS (C) 2009 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('pika-danio.php');
pika_init();

// Unconditional, not wrapped in a REQUEST_METHOD === 'POST' test like most
// of the other handlers, because this page dispatches a mutating action out
// of the query string: ?action=update_pba mass-assigns $_GET onto a
// pb_attorneys row and can reset that attorney's password.
//
// pl_csrf_check() does two different jobs. On a POST it validates the
// per-session token. On any other method it falls through to
// pl_request_cross_site_verdict() and refuses a 'cross' verdict, which is
// the only defence a GET-dispatched write has. Wrapping the call in a POST
// test removes exactly that half.
//
// A typed URL, a bookmark and an emailed link all read as 'unknown' and are
// still allowed through, so this costs nothing a user would notice. See
// pl_csrf_check() in cms/app/lib/pl.php.
pl_csrf_check();
require_once('plFlexList.php');
require_once('pikaMisc.php');
require_once('pikaTempLib.php');
require_once('pikaPbAttorney.php');





$C = '';
$filter = array();

$pba_id = pl_grab_get('pba_id');

$county = pl_grab_get('county');
$languages = pl_grab_get('languages');
$practice_areas = pl_grab_get('practice_areas');
$last_name = pl_grab_get('last_name');


$order = pl_grab_get('order','ASC');
$order_field = pl_grab_get('order_field','atty_name');
$offset = pl_grab_get('offset');
$page_size = $_SESSION['paging'];
$screen = pl_grab_get('screen');
$action = pl_grab_get('action');
$case_id = pl_grab_get('case_id');
$field = pl_grab_get('field');

$base_url = pl_settings_get('base_url');
$a = $main_html = array();


if ($auth_row['pba'] != true && $auth_row['group_name'] != 'system' && $screen != 'find_pb')
{
	$main_html['page_title'] = "Pro Bono Attorneys";
	$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
							Pro Bono Attorneys";
	$main_html['content'] = 'Access denied';
	
	$default_template = new pikaTempLib('templates/default.html',$main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}

switch ($action) {
	case 'update_pba':
		// The entry guard above deliberately exempts screen=find_pb so
		// non-PBA staff can use the find-an-attorney picker. That exemption
		// MUST NOT extend to mutating actions - without this gate any
		// authenticated user could request
		// ?screen=find_pb&action=update_pba&pba_id=N&password=Y
		// and reset any pro bono attorney's password (CWE-285 / CWE-269).
		if (!($auth_row['pba'] == true || $auth_row['group_name'] == 'system'))
		{
			$main_html['page_title'] = "Pro Bono Attorneys";
			$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
									Pro Bono Attorneys";
			$main_html['content'] = 'Access denied';
			
			$default_template = new pikaTempLib('templates/default.html',$main_html);
			$buffer = $default_template->draw();
			pika_exit($buffer);
		}
		$pba = new pikaPbAttorney($pba_id);
		// This mass-assigned $_GET straight into the row. Every other save
		// path in the tree routes its input through pl_clean_form_input()
		// first, and the unescaped renderers downstream were written against
		// that invariant, so restore it here too.
		$pba_row = pl_clean_form_input($_GET);
// AMW - added this for the VAM.
		$password = pl_grab_get('password');

		if(strlen($password) > 0) {
			// bcrypt, not md5 (CWE-916). PBA passwords are not consumed by
			// any in-tree login flow - pikaAuthDb authenticates against the
			// users table, not pb_attorneys - so there is no verify side to
			// migrate here. Any external consumer reading
			// pb_attorneys.password must accept both bcrypt ($2y$ prefix)
			// and legacy md5 hashes still on disk. New resets are bcrypt.
			$pba_row['password'] = password_hash($password, PASSWORD_DEFAULT);
		}

		else
		{
			unset($pba_row['password']);
		}
// AMW - End
		unset($pba_row['pba_id']);
		$pba->setValues($pba_row);
		$pba->save();
		header("Location:{$base_url}/pb_attorneys.php");
	break;
}


switch ($screen)
{
	case 'new_pb':
	
	$template = new pikaTempLib('subtemplates/pb_attorneys.html',$a,'edit_pba');
	$main_html['content'] = $template->draw();
	$main_html['content'] .= file_get_contents('js/form_save.js');
	$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
						<a href\"{$base_url}/pb_attorneys.php\">Pro Bono Attorneys &gt;
						Adding New Attorney";
	
	break;
	
	case 'edit_pb':
	
	$order_field = pl_grab_get('order_field','open_date');
	$order = pl_grab_get('order','DESC');
	$pba = new pikaPbAttorney($pba_id);
	$pba_row = $pba->getValues();
	$pba_row['atty_name'] = pl_text_name($pba_row);
	if(strlen($pba_row['atty_name']) < 1) {$pba_row['atty_name'] = "No Name";}
	
	
	$staff_array = pikaMisc::fetchStaffArray();
	
	// pba case list
	$pba_case_list = new plFlexList();
	$pba_case_list->template_file = 'subtemplates/case_list.html';
	$pba_case_list->get_url = "screen=edit_pb&pba_id={$pba_id}&";
	$pba_case_list->order_field = $order_field;
	$pba_case_list->order = $order;

// AMW 2014-07-23 - Added for SMRLS and ILCM.
$sresult = DB::query("DESCRIBE cases supervisor");
if (DBResult::numRows($sresult) == 1)
{
	$pba_case_list->column_names = array('number', 'client_name', 'status', 'user_id', 'supervisor', 'office', 'problem', 'funding', 'open_date', 'close_date');
}

else
{
	$pba_case_list->column_names = array('number', 'client_name', 'status', 'user_id', 'office', 'problem', 'funding', 'open_date', 'close_date');
}
	
	$case_count = 0;
	$i = 1;
	$result = pikaMisc::getCases(array('pba_id' => $pba_id), $case_count, $order_field, $order, 0, 3000);
	while ($row = DBResult::fetchRow($result))
	{
		
		$row['base_url'] = $base_url;
		$row['row_class'] = $i;
	
		if ($i > 1){
			$i = 1;
		}else {
			$i++;
		}
		if (strlen($row['close_date']) > 0) 
		{
			$row['open_closed'] = "Closed";
			$row['open_closed_color'] = "#ff0000";
		}

		else
		{
			$row['open_closed'] = "Open";
			$row['open_closed_color'] = "#008800";
		}
		
		if(!$row['number']){
			$row['number']= 'No Case #';
		} 
		
		if ($_SESSION['popup'] == true){
			$row['link_target'] = " target=\"_blank\"";
		}
		
		$row['client_name'] = pl_text_name($row,'contacts.');
		$row['user_id'] = pl_array_lookup($row['user_id'],$staff_array);
		
		// AMW 2014-07-23 - Added for SMRLS and ILCM.
		if (array_key_exists('supervisor', $row))
		{
			$row['supervisor'] = pl_array_lookup($row['supervisor'], $staff_array);		
		}
		
		$row['open_date'] = pl_date_unmogrify($row['open_date']);
		$row['close_date'] = pl_date_unmogrify($row['close_date']);
		
		if ($row['unread_sms'] > 0)
		{
			$row['unread_sms'] = "<a href=\"{$base_url}/case.php?case_id={$row['case_id']}&screen=sms\"><span class=\"badge badge-info\">{$row['unread_sms']}</span></a>&nbsp;";
		}
		
		else 
		{
			$row['unread_sms'] = '';
		}
				
		$pba_case_list->addHtmlRow($row);
		
		
	}
	
	
	$pba_row['case_list'] = $pba_case_list->draw();
	
	
	$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
						<a href=\"{$base_url}/pb_attorneys.php\">Pro Bono Attorneys</a> &gt;
						{$pba_row['atty_name']}";
	
	$template = new pikaTempLib('subtemplates/pb_attorneys.html',$pba_row,'edit_pba');
	$main_html['content'] = $template->draw();
	$main_html['content'] .= file_get_contents('js/form_save.js');
	
	
	break;
	
	case 'find_pb':
	default:
	
	if($screen != 'find_pb') {
		$a['add_link'] = "<img src='{$base_url}/images/point.gif'>
						 <a href='{$base_url}/pb_attorneys.php?screen=new_pb'>Add New Attorney</a>";
	}
	
	
	if ($county)
	{
		$filter['county'] = $county;
	}
	
	if ($languages)
	{
		$filter['languages'] = $languages;
	}
	
	if ($practice_areas)
	{
		$filter['practice_areas'] = $practice_areas;
	}
	
	if ($last_name)
	{
		$filter['last_name'] = $last_name;
	}
	
	if (!$offset)
	$offset = 0;
	
	
	$pba_count = 0;
	
	$pba_list = new plFlexList();
	$pba_list->template_file = 'subtemplates/pb_attorneys.html';
	$pba_list->column_names = array('atty_name','last_case','firm','address','phone_notes','email','county','languages','practice_areas','notes');
	$pba_list->table_url = "{$base_url}/pb_attorneys.php";
	$pba_list->get_url = "last_name={$last_name}&county={$county}&languages={$languages}&practice_areas={$practice_areas}&case_id={$case_id}&field={$field}&pba_id={$pba_id}&screen={$screen}&";
	$pba_list->order_field = $order_field;
	$pba_list->order = $order;
	$pba_list->records_per_page = $page_size;
	$pba_list->page_offset = $offset;
	
	$result = pikaPbAttorney::getPbAttorneys($filter, $pba_count, $order_field, $order, $offset, $page_size);
	
	while ($row = DBResult::fetchRow($result))
	{
		// Escapes atty_address and the seven other DB-sourced columns the
		// subtemplate renders raw. atty_name is built below and escaped
		// there, because the two screens build it differently.
		$row = pikaPbAttorney::decorateListRow($row);
		
		// The attorney name is DB-sourced and lands in a text node either
		// way, so it is escaped once here. It used to be interpolated raw
		// into both branches, which made this a stored-XSS sink.
		$pba_name = pl_html_escape(trim("{$row['last_name']}, {$row['first_name']} {$row['middle_name']} {$row['extra_name']}"));
		
		if ('find_pb' == $screen)
		{
			/*	A POST form, not a link. dataops.php's set_case_pba assigns
				a pro bono attorney to a case slot, and it reads its inputs
				from POST only so that the file-level pl_csrf_check() covers
				it. The <a href> that used to be here submitted nothing that
				handler could act on, so this screen could not assign an
				attorney at all.
				
				The flex row is rendered between the two forms in
				subtemplates/pb_attorneys.html rather than inside either, so
				this form does not nest.
			*/
			$row['atty_name'] = "<form action=\"dataops.php\" method=\"POST\" class=\"d-inline\">"
				. pl_csrf_hidden_input()
				. "<input type=\"hidden\" name=\"action\" value=\"set_case_pba\">"
				. "<input type=\"hidden\" name=\"case_id\" value=\"" . (int) $case_id . "\">"
				. "<input type=\"hidden\" name=\"field\" value=\"" . pl_html_escape((string) $field) . "\">"
				. "<input type=\"hidden\" name=\"pba_id\" value=\"" . (int) $row['pba_id'] . "\">"
				. "<button type=\"submit\" class=\"btn btn-link p-0 align-baseline\">{$pba_name}</button>"
				. "</form>";
		}
		
		else
		{
			// The href was unquoted as well, so a pba_id that was ever
			// non-numeric would end the attribute at the first space.
			$row['atty_name'] = "<a href=\"pb_attorneys.php?screen=edit_pb&amp;pba_id=" . (int) $row['pba_id'] . "\">{$pba_name}</a>";
		}
		
		$pba_list->addHtmlRow($row);
	}
	$pba_list->total_records = $pba_count;
	if ($pba_count > 0) {
		$a['total_pba'] = "{$pba_count} Pro Bono Attorney(s) found";
	}

	$a['order_field'] = $order_field;
	$a['order'] = $order;
	$a['screen'] = $screen;
	$a['languages'] = $languages;
	$a['county'] = $county;
	$a['practice_areas'] = $practice_areas;
	$a['last_name'] = $last_name;
	$a['atty_list'] = $pba_list->draw();
	$template = new pikaTempLib('subtemplates/pb_attorneys.html',$a,'find_pb');
	$main_html['content'] = $template->draw();
	$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
						Pro Bono Attorneys";
	
	
	break;
}



$main_html['page_title'] = "Pro Bono Attorneys";

$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
