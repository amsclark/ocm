<?php 

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once ('pika_cms.php');

$pk = new pikaCms;

$pbalist = new plTable();

$C = '';
$do_search = false;
$filter = array();

$county = pl_grab_var('county');
$languages = pl_grab_var('languages');
$practice_areas = pl_grab_var('practice_areas');
$last_name = pl_grab_var('last_name');
$order = pl_grab_var('order');
$order_field = pl_grab_var('order_field');
$offset = pl_grab_var('offset');
$screen = pl_grab_var('screen', null, 'REQUEST');
$case_id = pl_grab_var('case_id', null, 'REQUEST');
$field = pl_grab_var('field', null, 'REQUEST');

if ($auth_row['pba'] != true && $auth_row['group_name'] != 'system' && $screen != 'find_pb')
{
	$plTemplate["page_title"] = "Assign an Attorney";
	$plTemplate['nav'] = "<a href=\".\" class=light>$pikaNavRootLabel</a> &gt; Assign an Attorney";
	$plTemplate["content"] = 'Access denied';
	
	echo pl_template($plTemplate, 'templates/default.html');
	echo pl_bench('results');
	exit();
}

if (!$case_id || !$field)
{
	$plTemplate["page_title"] = "Assign an Attorney";
	$plTemplate['nav'] = "<a href=\".\" class=light>$pikaNavRootLabel</a> &gt; Assign an Attorney";
	$plTemplate["content"] = 'Need more information.';
	
	echo pl_template($plTemplate, 'templates/default.html');
	echo pl_bench('results');
	exit();
}



if ($county)
{
	$filter['county'] = $county;
	$do_search = true;
}

if ($languages)
{
	$filter['languages'] = $languages;
	$do_search = true;
}

if ($practice_areas)
{
	$filter['practice_areas'] = $practice_areas;
	$do_search = true;
}

if ($last_name)
{
	$filter['last_name'] = $last_name;
	$do_search = true;
}

if (!$offset)
$offset = 0;

$columns[] = "Name";
$columns[] = "Last Case";
$columns[] = "Firm";
$columns[] = "Address";
$columns[] = "Phone";
$columns[] = "Email";
$columns[] = "County";
$columns[] = "Languages";
$columns[] = "Practice Areas";
$columns[] = "Notes";

$pba_count = 0;
$atty_table_str = '';
$z = array();
$z = $filter;

if ($do_search)
{
$result = pika_get_attorneys($filter, $pba_count, $offset, $pikaDefPaging);

while ($row = DBResult::fetchRow($result))
{
	$row['full_address'] = pl_format_address($row);
	$row['full_name'] = pl_format_name($row);
	$row['extra_info'] = '';
	
	if ($row['attorney'] == 1)
	{
		$row['extra_info'] .= "<br>Staff Attorney";
	}
	
	else if ($row['attorney'] == 2)
	{
		$row['extra_info'] .= "<br>Volunteer Attorney";
	}
	
	else 
	{
		$row['extra_info'] .= "<br><strong>Not an Attorney</strong>";
	}
	
	if ($row['email'])
	{
		$row['extra_info'] .= '<br>' . pl_html_text($row['email']);
	}
			
	//$row['full_phone'] = pl_format_phone($row);
	/*	Both of these land in value="..." in the atty_table rows, so they are
		escaped here rather than in the template, which substitutes raw.
	*/
	$row['case_id'] = pl_html_escape($case_id);
	$row['field'] = pl_html_escape($field);
	
	$atty_table_str .= pl_template('subtemplates/assign_atty.html', $row, 'atty_table');
}
}

else 
{
	$z['atty_message'] = 'Please enter search parameters.';
}

$z['atty_table'] = $atty_table_str;

/*	Everything below this line is the search form at the top of the screen,
	and every value in it came from the request: $z started as $filter, which
	is built out of pl_grab_var() above, and case_id and field are request
	values too.

	pl_grab_var()'s default filter only turns < and > into entities, so none of
	these can open a tag -- but the template puts them inside quoted
	attributes, two of them single-quoted, and a quote is not on that list:

		?case_id=1' zzatty=1 x='

	came back as <input type=hidden name='case_id' value='1' zzatty=1 x=''>,
	with two attributes of the attacker's choosing added to the tag. The
	current CSP stops an on* attribute added that way from running, so this is
	attribute injection rather than script execution today; it is still the
	page emitting markup the request wrote.

	Escaped here and not in the template because pl_template_sub() substitutes
	raw, and not in $filter because $filter is the search itself -- escaping it
	there would look for an attorney whose county is "O&#039;Brien".
*/
foreach (array('county', 'languages', 'practice_areas', 'last_name') as $z_field)
{
	if (isset($z[$z_field]))
	{
		$z[$z_field] = pl_html_escape($z[$z_field]);
	}
}

$z['case_id'] = pl_html_escape($case_id);
$z['field'] = pl_html_escape($field);

$plTemplate['nav'] = "<a href=\".\">$pikaNavRootLabel</a> &gt; Assign an Attorney";
$plTemplate["content"] = pl_template('subtemplates/assign_atty.html', $z);
$plTemplate["page_title"] = "Assign an Attorney";


echo pl_template($plTemplate, 'templates/default.html');
echo pl_bench('results');
exit();

?>
