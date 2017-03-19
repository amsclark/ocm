<?php	

require_once('plFlexList.php');

$z = '';
$list_limit = 15;

pl_menu_get('case_status');

$base_url = pl_settings_get('base_url');

$pri = new plFlexList();
$names = new plFlexList();
$ssn = new plFlexList();


$pri->template_file = 'subtemplates/case-conflict.html';
$names->template_file = 'subtemplates/case-conflict.html';
$ssn->template_file = 'subtemplates/case-conflict.html';

//$columns = array('Issue', 'Case Number', 'Problem', 'Status');
$pri_count = 0;
$names_count = 0;
$ssn_count = 0;

$pri->sortable = FALSE;
$pri->show_pager = FALSE;
$names->sortable = FALSE;
$names->show_pager = FALSE;
$ssn->sortable = FALSE;
$ssn->show_pager = FALSE;

$case1 = new pikaCase($case_id);

// This is necessary on every page view - example: client is added as opposing party in newer case
$case_row['poten_conflicts'] = $case1->resetConflictStatus(false);
$cons = $case1->fuzzyConflictCheck($list_limit);

foreach ($cons as $val)
{
	$val['full_address'] = pl_html_address($val);
	$val['conflict_name'] = pl_text_name($val);
	
	if (!$val['number'])
	{
		$val['number'] = "an un-numbered case";
	}
	
	if ('ID' == $val['match'])
	{
		$pri->addRow($val);
		$pri_count++;
	}
	
	else if ('NAME' == $val['match'])
	{
		$names->addRow($val);
		$names_count++;
	}
	
	else 
	{
		$ssn->addRow($val);
		$ssn_count++;
	}
}

$z .= "<h2 class=\"conflict\">Primary Conflict Check</h2>\n";
if ($pri_count == 0)
{
	$z .= "<p><em>No conflicts found.</em>\n";
}
else
{
	$z .= $pri->draw();
	
	if ($pri_count >= $list_limit)
	{
		$z .= "<p>NOTICE:  Too many conflicts were found; not all are displayed here.</p>";
	}
}

$z .= "<br><h2 class=\"conflict\">Name-based Conflict Check</h2>\n";
if ($names_count == 0)
{
	$z .= "<p><em>No conflicts found.</em>\n";
}
else
{
	$z .= $names->draw();
	
	if ($names_count >= $list_limit)
	{
		$z .= "<p>NOTICE:  Too many conflicts were found; not all are displayed here.</p>";
	}
}

$z .= "<br><h2 class=\"conflict\">SSN-based Conflict Check</h2>\n";
if ($ssn_count == 0)
{
	$z .= "<p><em>No conflicts found.</em>\n";
}
else
{
	$z .= $ssn->draw();
	
	if ($ssn_count >= $list_limit)
	{
		$z .= "<p>NOTICE:  Too many conflicts were found; not all are displayed here.</p>";
	}
}

$z .= "<p><i class=\"material-icons forward\">forward</i> <a href=\"{$base_url}/reports/conflict/conflict.php?case_id={$case_row['case_id']}\" target=\"_new\">View full conflict list</a>";

$a['conflicts'] = $case_row["conflicts"];
$a['case_id'] = $case_id;
$a['flex_header'] = $z;

$C .= pl_template($a, 'subtemplates/case-conflict.html');

?>
