<?php

define('PIKA_NO_COMPRESSION', 1);

// AMW 2004-01-02
// See http://php3.de/manual/en/function.session-cache-limiter.php
$pikaAllowCaching = true;

require_once ('pika_cms.php');

unset($C);
unset($a);

$pk = new pikaCms;

$report = '';
$C = '';
$plMenus['output_format'] = array('pdf' => 'PDF', 'html' => 'HTML');

/*
$url_parts = explode('/', $REQUEST_URI);
$url_parts = array_reverse($url_parts);
$report = $url_parts[1];
*/

if (isset($_GET['report']))
{
	$report = pl_clean_path_chars($_GET['report']);
}


/*	Read access to the case is checked here, before anything is included.

	The two stock per-case forms check it themselves, and have to, because both
	can be requested directly. This check is for what else this dispatcher can
	reach. The branch below prefers
	pl_custom_directory()/extensions/case_print/case_print-form.php whenever that
	file exists - for any value of $report, not just case_print - and a
	deployment's own copy of that form lives outside this repository, so nothing
	here can make it hold a gate. Checking before the include puts every form
	this file can run behind one.

	A report that names no case is unaffected: with no case_id in the request
	there is nothing to check.

	A case_id that is not a positive integer, or that names no case, is answered
	with the same refusal as a case the caller may not read, so the answer cannot
	be used to tell real case numbers from invented ones.
*/
$lr_case_id = pl_grab_var('case_id');

if (!is_null($lr_case_id) && '' !== $lr_case_id)
{
	$lr_base_url = pl_settings_get('base_url');
	$lr_case_id = filter_var($lr_case_id, FILTER_VALIDATE_INT,
		array('options' => array('min_range' => 1)));

	if (false === $lr_case_id)
	{
		pl_case_not_viewable($lr_base_url);
	}

	$lr_result = DB::query("SELECT * FROM cases WHERE case_id = "
		. (int) $lr_case_id . " LIMIT 1");

	if (!$lr_result || DBResult::numRows($lr_result) < 1)
	{
		pl_case_not_viewable($lr_base_url);
	}

	if (!pika_authorize('read_case', DBResult::fetchRow($lr_result)))
	{
		pl_case_not_viewable($lr_base_url);
	}
}


if (!$report)
{
	$C .= "<p>Available reports:</p>";
	/*
	$C .= '<ul>';
	
	// TODO - get rid of this
	$pikaAvailableReports = pika_report_list();
	
	while (list($key, $val) = each($pikaAvailableReports))
	{
		$C .= "<li><a href='report.php?report=$val'>$val</a>\n";
	}
	
	$C .= "</ul>\n";
	*/
	$C .= pika_html_report_list();
	$report_title = "All Reports";
}

else
{
	$case_print_path = pl_custom_directory() . "/extensions/case_print/case_print-form.php";
	if (file_exists($case_print_path))
	{
		include($case_print_path);
	}
	
	else if (file_exists("reports/{$report}/{$report}-form.php"))
	{
		include("reports/{$report}/{$report}-form.php");
	}

	else
	{
		die(pika_error_notice('Pika is sick', "Can't find the file 'reports/{$report}/{$report}-form.php'"));
	}
}

$plTemplate["content"] = $C;
$plTemplate["page_title"] = $report_title;
$plTemplate['nav'] = "<a href=\".\" class=light>$pikaNavRootLabel</a> &gt; <a href=\"reports/\" class=light>Reports</a> &gt; $report_title";

echo pl_template($plTemplate, 'templates/default.html');
echo pl_bench('results');
exit();

?>
