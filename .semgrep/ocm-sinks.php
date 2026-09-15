<?php

/*	Unit tests for the rules in ocm-sinks.yml.

	Run with:

		semgrep --metrics=off --test --config .semgrep .semgrep

	Each statement below carries an annotation comment on the line above it,
	naming one rule. The positive form asserts that rule reports the statement;
	the negative form asserts the rule stays quiet. A statement a rule matches
	with no annotation above it fails the test, so a rule that starts matching
	more than it should is caught here too. semgrep reads the annotations
	itself, so this comment cannot spell them out -- it would be read as one.

	This file is never included by the application. It is deliberately full of
	code that would be defects if it were real, which is the point: a rule that
	has silently stopped matching reports a clean scan, and only a test that
	feeds it a known-bad case can tell the difference between "nothing wrong"
	and "not looking".

	Keep the negative cases. They are what stops a rule being widened until it
	flags every query in the tree and gets switched off.
*/

// -----------------------------------------------------------------------------
// ocm-sql-injection
// -----------------------------------------------------------------------------

function sql_bad_concat_from_helper()
{
	$case_id = pl_grab_get('case_id', 0);

	// ruleid: ocm-sql-injection
	return DB::query("SELECT * FROM cases WHERE case_id = '" . $case_id . "'");
}

function sql_bad_superglobal()
{
	// ruleid: ocm-sql-injection
	return DB::query("SELECT * FROM cases WHERE number = '" . $_GET['number'] . "'");
}

function sql_bad_post_interpolated()
{
	$name = pl_grab_post('last_name');

	// ruleid: ocm-sql-injection
	return DB::query("SELECT * FROM contacts WHERE last_name = '$name'");
}

function sql_bad_legacy_wrapper()
{
	// pl_query() is a wrapper straight onto DB::query(), so it is the same sink.
	// ruleid: ocm-sql-injection
	return pl_query("SELECT * FROM cases WHERE office = '" . pl_grab_get('office', '') . "'");
}

function sql_bad_grab_var()
{
	// ruleid: ocm-sql-injection
	return DB::query("DELETE FROM notes WHERE note_id = '" . pl_grab_var('note_id') . "'");
}

function sql_ok_escaped()
{
	$number = DB::escapeString(pl_grab_get('number', ''));

	// ok: ocm-sql-injection
	return DB::query("SELECT * FROM cases WHERE number = '" . $number . "'");
}

function sql_ok_cast()
{
	// ok: ocm-sql-injection
	return DB::query("SELECT * FROM cases WHERE case_id = " . (int) pl_grab_get('case_id', 0));
}

function sql_ok_intval()
{
	// ok: ocm-sql-injection
	return DB::query("SELECT * FROM cases WHERE case_id = " . intval($_GET['case_id']));
}

function sql_ok_number_mode()
{
	// 'number' mode replaces a non-numeric value with null, so nothing that
	// could close the quote survives the read.
	// ok: ocm-sql-injection
	return DB::query("SELECT * FROM cases WHERE case_id = '" . pl_grab_get('case_id', 0, 'number') . "'");
}

function sql_ok_identifier_allowlist()
{
	$column = pl_safe_identifier(pl_grab_get('sort', 'case_id'));

	// ok: ocm-sql-injection
	return DB::query("SELECT $column FROM cases LIMIT 10");
}

function sql_ok_prepared()
{
	// DB::preparedQuery() binds every parameter, so the request value never
	// reaches the statement text.
	// ok: ocm-sql-injection
	return DB::preparedQuery(
		'SELECT * FROM cases WHERE number = ?',
		array(pl_grab_get('number', ''))
	);
}

function sql_ok_comma_vals()
{
	/*	pl_process_comma_vals() escapes each value and supplies the quotes and
		the parentheses itself, so the clause must NOT add any. This is the
		shape most of the LSC reports use.
	*/
	$offices = pl_process_comma_vals(pl_grab_post('office'));

	// ok: ocm-sql-injection
	return DB::query("SELECT * FROM cases WHERE 1 AND office IN $offices");
}

function sql_ok_comparison_operator_allowlist()
{
	$op = pl_safe_comparison_operator(pl_grab_post('fcomp0'));
	$value = DB::escapeString(pl_grab_post('fvalue0'));

	// ok: ocm-sql-injection
	return DB::query("SELECT * FROM cases WHERE case_id $op '$value'");
}

function sql_ok_literal()
{
	// ok: ocm-sql-injection
	return DB::query('SELECT count(*) FROM cases');
}

// -----------------------------------------------------------------------------
// ocm-xss-raw-html
// -----------------------------------------------------------------------------

function xss_bad_html_row_from_request($list)
{
	$search = pl_grab_get('q', '');

	// ruleid: ocm-xss-raw-html
	$list->addHtmlRow(array('label' => 'Searched for', 'value' => $search));
}

function xss_bad_template_sub()
{
	// ruleid: ocm-xss-raw-html
	return pl_template_sub('<p>%%[q]%%</p>', array('q' => pl_grab_get('q', '')));
}

function xss_ok_html_row_escaped($list)
{
	$search = pl_html_escape(pl_grab_get('q', ''));

	// ok: ocm-xss-raw-html
	$list->addHtmlRow(array('label' => 'Searched for', 'value' => $search));
}

function xss_ok_html_row_number($list)
{
	// ok: ocm-xss-raw-html
	$list->addHtmlRow(array('case_id' => (int) pl_grab_get('case_id', 0)));
}

function xss_ok_escaping_add_row($list)
{
	/*	plFlexList::addRow() runs pl_clean_html_array() over the whole row, so
		it is not a sink and the rule must not name it. This case fails if
		anyone adds addRow() back to the sink list.
	*/
	// ok: ocm-xss-raw-html
	$list->addRow(array('q' => pl_grab_get('q', '')));
}

function xss_ok_tainted_receiver_clean_row($list, $row)
{
	/*	The request value sets a property on the list object and never reaches
		a cell. semgrep taints the whole object when a property of it is
		assigned a tainted value, so without focus-metavariable on the sink
		argument this reads as a finding -- which is what it did on five list
		pages that already escape their rows.
	*/
	$list->page_offset = pl_grab_get('offset', '0', 'number');
	$list->order = pl_grab_get('order', 'DESC');

	// ok: ocm-xss-raw-html
	$list->addHtmlRow(pl_clean_html_array($row));
}

// -----------------------------------------------------------------------------
// ocm-file-inclusion
// -----------------------------------------------------------------------------

function include_bad_from_request()
{
	$report = pl_grab_get('report', '');

	// ruleid: ocm-file-inclusion
	include 'reports/' . $report . '.php';
}

function include_bad_require_once()
{
	// ruleid: ocm-file-inclusion
	require_once $_GET['module'];
}

function include_ok_cleaned()
{
	$report = pl_clean_file_name(pl_grab_get('report', ''));

	// ok: ocm-file-inclusion
	include 'reports/' . $report . '.php';
}

function include_ok_fixed_list()
{
	/*	The path is a literal chosen by a comparison, so no request value is
		part of it. This is the shape the rule's message asks for.
	*/
	switch (pl_grab_get('report', ''))
	{
		case 'summary':
			// ok: ocm-file-inclusion
			include 'reports/summary.php';
			break;

		case 'closed':
			// ok: ocm-file-inclusion
			include 'reports/closed.php';
			break;
	}
}

function include_allowlist_lookup_is_still_reported()
{
	/*	A known limitation, recorded here so it is not a surprise. An allowlist
		keyed by the request value IS safe -- the value only picks a row, and
		the path comes from the table -- but taint analysis follows the index
		into the lookup and reports it anyway. If this shape appears in the
		application, assign the literal out of the table first and include the
		variable holding it, or use the switch above.
	*/
	$allowed = array('summary' => 'reports/summary.php');
	$key = pl_grab_get('report', '');

	if (!isset($allowed[$key]))
	{
		return;
	}

	// ruleid: ocm-file-inclusion
	include $allowed[$key];
}

// -----------------------------------------------------------------------------
// ocm-command-injection
// -----------------------------------------------------------------------------

function exec_bad_from_request()
{
	$file = pl_grab_post('file');

	// ruleid: ocm-command-injection
	exec('pdftotext ' . $file . ' -');
}

function exec_ok_escaped()
{
	$file = escapeshellarg(pl_grab_post('file'));

	// ok: ocm-command-injection
	exec('pdftotext ' . $file . ' -');
}

function exec_ok_clean_file_name()
{
	$file = pl_clean_file_name(pl_grab_post('file'));

	// ok: ocm-command-injection
	exec('pdftotext documents/' . $file . ' -');
}

// -----------------------------------------------------------------------------
// ocm-open-redirect
// -----------------------------------------------------------------------------

function redirect_bad_whole_url_from_request()
{
	$next = pl_grab_get('next', '');

	// ruleid: ocm-open-redirect
	header('Location: ' . $next);
}

function redirect_bad_interpolated()
{
	$next = pl_grab_get('next', '');

	// ruleid: ocm-open-redirect
	header("Location: $next");
}

function redirect_ok_our_own_path($base_url)
{
	/*	The URL starts with a literal of our own, so the request value can only
		choose a parameter on a page of ours -- and PHP has rejected a CR or LF
		in a header value since 5.1.2, so it cannot start a second header
		either. This is the shape eighty-odd redirects in this tree use, and
		the rule must stay quiet on it.
	*/
	$case_id = pl_grab_get('case_id', 0);

	// ok: ocm-open-redirect
	header("Location: {$base_url}/case.php?case_id={$case_id}");
}

function redirect_ok_encoded_parameters($base_url)
{
	/*	The URL is built from a literal of our own plus percent-encoded
		parameters, and then held in one variable -- which is the shape the
		rule's regex is looking for, so the encoding is what has to answer
		for it. A urlencode()d value carries no ":", "/", "?" or "#", so it
		cannot end the path and name a host.
	*/
	$next = "{$base_url}/activity.php?date_lock_error=1"
		. '&case_id=' . urlencode((string) pl_grab_post('case_id'));

	// ok: ocm-open-redirect
	header("Location: {$next}");
}

function redirect_ok_cast()
{
	// ok: ocm-open-redirect
	header('Location: ' . (int) pl_grab_get('case_id', 0));
}

// -----------------------------------------------------------------------------
// ocm-unserialize-without-allowed-classes
// -----------------------------------------------------------------------------

function unserialize_bad_bare($blob)
{
	// ruleid: ocm-unserialize-without-allowed-classes
	return unserialize($blob);
}

function unserialize_ok_no_classes($blob)
{
	// ok: ocm-unserialize-without-allowed-classes
	return unserialize($blob, array('allowed_classes' => false));
}

function unserialize_ok_short_array($blob)
{
	// ok: ocm-unserialize-without-allowed-classes
	return unserialize($blob, ['allowed_classes' => false]);
}
