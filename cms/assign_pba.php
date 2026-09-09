<?php 

/**********************************/
/* Pika CMS (C) 2009 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('pika-danio.php');
pika_init();

// This page performs its state changes on a GET: the action is dispatched
// out of the query string and the links that trigger it are plain <a href>
// markup, so a hidden token field is not available as a defence here.
// On a non-POST request pl_csrf_check() falls through to the same-site
// check, which refuses a mutation that a foreign page initiated and needs
// nothing from the markup. See pl_request_cross_site_verdict() in pl.php.
pl_csrf_check();
require_once('plFlexList.php');
require_once('pikaMisc.php');
require_once('pikaTempLib.php');
require_once('pikaPbAttorney.php');
require_once('pikaCase.php');





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

switch ($action)
{
	case 'assign_pba':
		// This file had no pika_authorize call anywhere in it. The assign
		// action mutates a pro bono attorney row and then hands
		// ops/update_case.php a case id plus a field name to write, so
		// without a gate any authenticated user could stamp a pro bono
		// assignment onto any case in the org by id.
		//
		// is_numeric() comes first because plBase::__construct() with an
		// empty id takes the new-row path and draws an id from the counters
		// table, which is a write this action has no reason to perform.
		if (!is_numeric($case_id))
		{
			die('Access denied');
		}
		
		$assign_case = new pikaCase($case_id);
		$assign_case_row = $assign_case->getValues();
		
		if (empty($assign_case_row['case_id']) || !pika_authorize('edit_case', $assign_case_row))
		{
			die('Access denied');
		}
		
		// $field named the column to write and went into the redirect raw,
		// so it was also a way to set an arbitrary case column through
		// update_case.php's mass assignment. Only the three pro bono slots
		// belong here.
		if (!in_array($field, array('pba_id1','pba_id2','pba_id3'), true))
		{
			die('Access denied');
		}
		
		if($pba_id && is_numeric($pba_id))
		{
			$pb_attorney = new pikaPbAttorney($pba_id);
			$pb_attorney->last_case = date('Y-m-d');
			$pb_attorney->save();
		}
		
		// The pro bono type used to be carried across here as
		// pba_type<n>={$pb_attorney->pb_type}, through a $type_filed typo
		// that made the parameter name empty. Neither pb_attorneys.pb_type
		// nor cases.pba_type1..3 exists in this schema, so the read was a
		// notice and the write was silently dropped by
		// plBase::setValue(). Removed rather than repaired.
		header("Location:{$base_url}/ops/update_case.php?case_id={$case_id}&{$field}={$pba_id}&screen=pb");
		break;
	default:
		// The browse screen is reached from a case's pro bono tab and every
		// row it renders links back into the assign action above, so it is
		// gated the same way. With no case_id it is just the pro bono
		// directory, which pb_attorneys.php gates on the group's pba flag.
		if ('' !== (string) $case_id)
		{
			if (!is_numeric($case_id))
			{
				die('Access denied');
			}
			
			$browse_case = new pikaCase($case_id);
			$browse_case_row = $browse_case->getValues();
			
			if (empty($browse_case_row['case_id']) || !pika_authorize('edit_case', $browse_case_row))
			{
				die('Access denied');
			}
		}
		else if ($auth_row['pba'] != true && $auth_row['group_name'] != 'system')
		{
			die('Access denied');
		}
		
		$filter = array();
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
		{
			$offset = 0;		
		}


		$pba_count = 0;

		$pba_list = new plFlexList();
		$pba_list->template_file = 'subtemplates/pb_attorneys.html';
		$pba_list->column_names = array('atty_name','last_case','firm','address','phone_notes','email','county','languages','practice_areas','notes');
		$pba_list->table_url = "{$base_url}/assign_pba.php";
		// These values end up inside HTML attributes. pl_grab_get() encodes
		// < and > and nothing else, so a single quote in any filter value
		// closed the attribute and gave a reflected XSS on a page that
		// renders inside the case screen.
		$pba_list->get_url = 'practice_areas=' . rawurlencode($practice_areas)
			. '&county=' . rawurlencode($county)
			. '&last_name=' . rawurlencode($last_name)
			. '&languages=' . rawurlencode($languages)
			. '&case_id=' . rawurlencode($case_id)
			. '&field=' . rawurlencode($field) . '&';
		$pba_list->order_field = $order_field;
		$pba_list->order = $order;
		$pba_list->records_per_page = $page_size;
		$pba_list->page_offset = $offset;

		$result = pikaPbAttorney::getPbAttorneys($filter, $pba_count, $order_field, $order, $offset, $page_size);

		while ($row = DBResult::fetchRow($result))
		{
			$row['atty_address'] = pl_text_address($row);
			$row['last_case'] = pl_date_unmogrify($row['last_case']);
			$atty_href = $base_url . '/assign_pba.php?action=assign_pba'
				. '&case_id=' . rawurlencode($case_id)
				. '&pba_id=' . rawurlencode($row['pba_id'])
				. '&field=' . rawurlencode($field)
				. '&screen=pb';
			$atty_label = pl_html_escape("{$row["last_name"]}, {$row["first_name"]} {$row["middle_name"]} {$row["extra_name"]}");
			$row['atty_name'] = "<a href='" . pl_html_escape($atty_href) . "'>{$atty_label}</a>";
			$pba_list->addHtmlRow($row);
		}

		$pba_list->total_records = $pba_count;
		if ($pba_count > 0) {
			$a['total_pba'] = "{$pba_count} Pro Bono Attorney(s) found";
		}


		$a['atty_list'] = $pba_list->draw();
		$a['field'] = $field;
		$a['case_id'] = $case_id;
		$a['screen'] = $screen;
		$a['county'] = $county;
		$a['languages'] = $languages;
		$a['practice_areas'] = $practice_areas;
		$a['last_name'] = $last_name;
		$a['order'] = $order;
		$a['order_field'] = $order_field;
		$template = new pikaTempLib('subtemplates/assign_pba.html',$a);
		$main_html['content'] = $template->draw();
		
		break;
}






$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
						Pro Bono Attorneys";

$main_html['page_title'] = "Pro Bono Attorneys";

$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);