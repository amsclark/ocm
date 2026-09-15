<?php 

/**********************************/
/* Pika CMS (C) 2009 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

chdir('../../');

require_once ('pika-danio.php'); 
pika_init();

$report_title = 'Mega Party Report';
$report_name = 'megapartyreport';

$base_url = pl_settings_get('base_url');
if(!pika_report_authorize($report_name)) {
	$main_html = array();
	$main_html['base_url'] = $base_url;
	$main_html['page_title'] = $report_title;
	$main_html['nav'] = "<a href=\"{$base_url}/\">Pika Home</a>
    				  &gt; <a href=\"{$base_url}/reports/\">Reports</a> 
    				  &gt; $report_title";
	$main_html['content'] = "You are not authorized to run this report";

	$buffer = pl_template('templates/default.html', $main_html);
	pika_exit($buffer);
}

$ffield0 = pl_grab_post('ffield0');
$ffield1 = pl_grab_post('ffield1');
$ffield2 = pl_grab_post('ffield2');
$ffield3 = pl_grab_post('ffield3');
$ffield4 = pl_grab_post('ffield4');
$ffield5 = pl_grab_post('ffield5');

$ffield = array($ffield0, $ffield1, $ffield2, $ffield3, $ffield4, $ffield5);

$fcomp0 = pl_grab_post('fcomp0');
$fcomp1 = pl_grab_post('fcomp1');
$fcomp2 = pl_grab_post('fcomp2');
$fcomp3 = pl_grab_post('fcomp3');
$fcomp4 = pl_grab_post('fcomp4');
$fcomp5 = pl_grab_post('fcomp5');

$fcomp = array($fcomp0,$fcomp1,$fcomp2,$fcomp3,$fcomp4,$fcomp5);

foreach ($fcomp as $key => $val)
{
	if ('&lt;' == $val)
	{
		$fcomp[$key] = '<';
	}
	
	else if ('&gt;' == $val)
	{
		$fcomp[$key] = '>';
	}
}

$fvalue0 = pl_grab_post('fvalue0');
$fvalue1 = pl_grab_post('fvalue1');
$fvalue2 = pl_grab_post('fvalue2');
$fvalue3 = pl_grab_post('fvalue3');
$fvalue4 = pl_grab_post('fvalue4');
$fvalue5 = pl_grab_post('fvalue5');

$fvalue = array($fvalue0,$fvalue1,$fvalue2,$fvalue3,$fvalue4,$fvalue5);

$sum = pl_grab_post('sum');
$count = pl_grab_post('count');
$order_by = pl_grab_post('order_by');
$order_by2 = pl_grab_post('order_by2');
$group_by = pl_grab_post('group_by');
$group_by2 = pl_grab_post('group_by2');
$users_list = pl_grab_post('users_list');
$recordlimit = pl_grab_post('recordlimit', 10000);
$relation_codes = pl_grab_post('relation_codes');

$fo = pl_grab_post('fo'); // Defines which columns to display, and in what order.

$showfields = '';  // This is basically the SELECT clause for the report query.
// to the SELECT clause, so the commas look correct.
$tables = array();  // Used to store table data type information.  Useful when determining
// which fields have dates or times that need to be mogrified.

$tables['cases'] = pl_table_fields_get('cases');
$tables['contacts'] = pl_table_fields_get('contacts');
$tables['activities'] = pl_table_fields_get('activities');

/*	Everything read above that reaches the query as an IDENTIFIER -- a column
	name in the SELECT list, in ORDER BY, in GROUP BY, or on the left of a
	comparison -- is held to pl_safe_identifier() here, before it is used.
	
	This report used to pass those names through DB::escapeString() instead,
	which is no protection at all in an identifier slot: escapeString() escapes
	quotes, and an identifier is not quoted, so a value like
	
		1, (SELECT password FROM users LIMIT 1)
	
	reached the SELECT list unchanged and the report printed whatever it named.
	The same value in the GROUP BY, ORDER BY or WHERE column slots worked the
	same way.
	
	Every one of these values comes from a <select> the report form builds from
	a fixed list, so a rejection means the request was not made by that form.
	Fail the whole report rather than dropping one clause: a report that
	silently ignored a filter would be read as if the filter had applied.
*/
$ident_inputs = array(
	'sum column'         => $sum,
	'count column'       => $count,
	'first sort column'  => $order_by,
	'second sort column' => $order_by2,
	'first group column' => $group_by,
	'second group column'=> $group_by2,
);

$fo_names = is_array($fo) ? $fo : array();

$bad_input = false;
$ident_safe = array();

foreach ($ident_inputs AS $context => $value)
{
	if (strlen((string) $value) < 1)
	{
		$ident_safe[$context] = '';
		continue;
	}

	$safe_ident = pl_safe_identifier($value, "megapartyreport $context");

	if (false === $safe_ident)
	{
		$bad_input = true;
		continue;
	}

	$ident_safe[$context] = $safe_ident;
}

/*	The display columns and the filter columns are lists, so they are
	validated straight into lists of their own rather than through
	$ident_safe under a made-up key. Appending each approved name keeps
	the value that reaches the query one step away from the allowlist
	that approved it.
	
	$fo and $ffield keep the raw request values and are not read again
	below. Everything that reaches the query reads $fo_safe or
	$ffield_safe, so which of the two a line uses is visible on that line.
*/
$fo_safe = array();

foreach ($fo_names AS $column)
{
	$safe_ident = pl_safe_identifier($column, 'megapartyreport display column');

	if (false === $safe_ident)
	{
		$bad_input = true;
		continue;
	}

	$fo_safe[] = $safe_ident;
}

/*	$ffield_safe has to stay the same length as $ffield. The WHERE clause
	below reads $fcomp and $fvalue by position, so dropping an element
	would apply one filter's comparison and value to the next filter's
	column. A rejected name becomes the empty string, which that loop
	skips -- and $bad_input ends the report before it runs anyway.
*/
$ffield_safe = array();

foreach ($ffield AS $column)
{
	if (strlen((string) $column) < 1)
	{
		$ffield_safe[] = '';
		continue;
	}

	$safe_ident = pl_safe_identifier($column, 'megapartyreport filter column');

	if (false === $safe_ident)
	{
		$bad_input = true;
		$ffield_safe[] = '';
		continue;
	}

	$ffield_safe[] = $safe_ident;
}

if ($bad_input)
{
	echo "<h1>Error:  this report was asked for a column it does not offer</h1>\n";
	exit();
}

/*	Read back what the allowlist returned, not what went into it.
	
	pl_safe_identifier() returns the name unchanged when it recognises
	it, so this changes nothing about which report you get. What it
	changes is where the guarantee lives. The query used to be built
	from the original request values and was safe only because of the
	exit() above: a check in one place protecting an interpolation three
	hundred lines further down. Anyone who later moved the query, added
	a second one, or returned an error instead of exiting would have
	removed the protection without touching the line that looks
	dangerous.
	
	An absent value becomes the empty string rather than staying null.
	Every use below is a truthiness test, so that reads the same.
*/
$sum       = $ident_safe['sum column'];
$count     = $ident_safe['count column'];
$order_by  = $ident_safe['first sort column'];
$order_by2 = $ident_safe['second sort column'];
$group_by  = $ident_safe['first group column'];
$group_by2 = $ident_safe['second group column'];

$report_format = pl_grab_post('report_format');
$show_sql = pl_grab_post('show_sql');



if ('csv' == $report_format)
{
	require_once ('app/lib/plCsvReportTable.php');
	require_once ('app/lib/plCsvReport.php');
	$r = new plCsvReport();
}

else
{
	require_once ('app/lib/plHtmlReportTable.php');
	require_once ('app/lib/plHtmlReport.php');
	$r = new plHtmlReport();
}

// BUILD SELECT CLAUSE
// When calcuating SUMs, only display the sum field, and the group_by field (if specified)
if ($sum && $group_by && $group_by2)
{
	$showfields = "$group_by, $group_by2, SUM($sum) as Sum";
}

else if ($sum && $group_by)
{
	$showfields = "$group_by, SUM($sum) as Sum";
}

else if ($sum)
{
	$showfields = "SUM($sum) as Sum";
}

else if ($count && $group_by && $group_by2)
{
	$showfields = "$group_by, $group_by2, COUNT($count) as Total";
}

else if ($count && $group_by)
{
	$showfields = "$group_by, COUNT($count) as Total";
}

else if ($count)
{
	$showfields = "COUNT($count) as Total";
}

else
{
	// pl_grab_post() answers null for a field that was never submitted, and
	// sizeof(null) is a fatal TypeError on PHP 8. Submitting the form with no
	// columns checked should reach the error message below, not a blank page.
	if (count($fo_safe) < 1)
	{
		echo "<h1>Error:  you need to check off the fields you want displayed on this report</h1>\n";
		exit();
	}
	
	else 
	{
		$z = implode(', ', $fo_safe);
		$showfields = $z;
	}
}

/*	No DB::escapeString() on $showfields any more. A SELECT list is not a
	quoted context, so escaping it removed nothing an attacker would have
	used.
	
	What makes this string safe is that every column name in it came back
	from pl_safe_identifier() -- $fo_safe, $group_by, $sum and $count are
	the allowlist's own return values, not the request values -- and the
	SUM(), COUNT() and "as Sum" text around them is written here rather
	than submitted.
*/


if (substr_count($showfields, 'activities.') > 0)
{
  $showfields .= ", activities.act_id AS act_id_deleteme";
		if (strlen($relation_codes) == 0)
    {
		  $sql = "SELECT {$showfields}  FROM activities
													          LEFT JOIN cases ON activities.case_id = cases.case_id 
																	  LEFT JOIN contacts ON cases.client_id = contacts.contact_id WHERE 1";
    } 
    else 
    {
		  $sql = "SELECT {$showfields}  FROM activities 
																	  LEFT JOIN cases ON activities.case_id = cases.case_id 
																		LEFT JOIN conflict on cases.case_id = conflict.case_id 
																		LEFT JOIN contacts ON conflict.contact_id = contacts.contact_id 
																		WHERE conflict.relation_code IN " . pl_process_comma_vals($relation_codes);
		}
}
else 
{
  if (strlen($relation_codes) == 0) 
  {
	  $sql = "SELECT {$showfields}  FROM cases 
										              LEFT JOIN contacts ON cases.client_id = contacts.contact_id WHERE 1";
	} 
  else 
  {
	$sql = "SELECT {$showfields}  FROM cases 
														    LEFT JOIN conflict ON cases.case_id = conflict.case_id 
																LEFT JOIN contacts ON conflict.contact_id = contacts.contact_id 
																WHERE conflict.relation_code IN " . pl_process_comma_vals($relation_codes);
	}
}

// BUILD WHERE CLAUSE
$i = 0;
$special_fields = array('counsel_id', 'pba_id');

foreach ($ffield_safe as $key => $val)
{
	if ($val)
	{
		/*	No DB::escapeString($val) here any more: $val is a column name,
			which is not quoted, so escaping it did nothing. It has already
			been held to pl_safe_identifier() with the rest of $ffield above,
			and the report exits if any name is rejected.
		*/
		list($table_name, $field_name) = explode('.', $val);
		$field_data_type = $tables[$table_name][$field_name];
		
		if (!in_array($val, $special_fields))
		{
			if ('is blank' == $fcomp[$i])
			{
				$sql .= " AND $val IS NULL";
			}
			
			else if ('is not blank' == $fcomp[$i])
			{
				$sql .= " AND $val IS NOT NULL";
			}
			
			else if ('=' == $fcomp[$i])
			{
				// use IN() comparison
				// first add quotes around each comma-separated search item
				$val_array = explode(",", $fvalue[$i]);
				$quoted_vals = '';
				$y = 0;
				foreach($val_array as $x)
				{
					$x = trim($x);
					$x = DB::escapeString($x);
					
					if ($field_data_type == 'date')
					{
						$field_value = pl_date_mogrify($x);
					}
					
					else if ($field_data_type == 'time')
					{
						$field_value = pl_time_mogrify($x);
					}

					else 
					{
						$field_value = $x;
					}
									
					if ($y > 0)
					{
						$quoted_vals .= ',';
					}
					
					$quoted_vals .= "'$field_value'";					
					$y++;
				}
								
				$sql .= " AND $val IN($quoted_vals)";
			}

			else if ('!=' == $fcomp[$i])
			{
				// use IN() comparison
				// first add quotes around each comma-separated search item
				$val_array = explode(",", $fvalue[$i]);
				$quoted_vals = '';
				$y = 0;
				foreach($val_array as $x)
				{
					$x = trim($x);
					$x = DB::escapeString($x);
					
					if ($field_data_type == 'date')
					{
						$field_value = pl_date_mogrify($x);
					}
					
					else if ($field_data_type == 'time')
					{
						$field_value = pl_time_mogrify($x);
					}

					else 
					{
						$field_value = $x;
					}
									
					if ($y > 0)
					{
						$quoted_vals .= ',';
					}
					
					$quoted_vals .= "'$field_value'";					
					$y++;
				}
								
				$sql .= " AND ($val NOT IN($quoted_vals) OR $val IS NULL)";
			}
			
			else if ('LIKE' == $fcomp[$i])
			{
				// use LIKE comparison
				// handle '*' as a wildcard - will only work on string fields
					if ($field_data_type == 'date')
					{
						$field_value = pl_date_mogrify($fvalue[$i]);
					}
					
					else if ($field_data_type == 'time')
					{
						$field_value = pl_time_mogrify($fvalue[$i]);
					}

					else 
					{
						$field_value = $fvalue[$i];
					}
				
				$field_value = str_replace('*', '%', $field_value);
				
				/*	The only branch in this loop that never escaped its value.
					It is interpolated inside single quotes, so a quote in the
					search text closed the string and the rest of it became
					SQL.
				*/
				$field_value = DB::escapeString($field_value);
				
				$sql .= " AND $val LIKE '$field_value'";
			}
			
			else if ('between' == $fcomp[$i])
			{
				$val_array = explode(",", $fvalue[$i]);
				$val_array[0] = trim($val_array[0]);
				$val_array[1] = trim($val_array[1]);
				
					if ($field_data_type == 'date')
					{
						$value_a = pl_date_mogrify($val_array[0]);
						$value_b = pl_date_mogrify($val_array[1]);
					}
					
					else if ($field_data_type == 'time')
					{
						$value_a = pl_time_mogrify($val_array[0]);
						$value_b = pl_time_mogrify($val_array[1]);
					}

					else 
					{
						//$field_value = $fvalue[$i];  - What is this???
						$value_a = $val_array[0];
						$value_b = $val_array[1];
					}
				
				$value_a = DB::escapeString($value_a);
				$value_b = DB::escapeString($value_b);
				
				$sql .= " AND ($val >= '$value_a' AND $val <= '$value_b')";
			}
			
			else if ($fvalue[$i])
			{
				/*	Every comparison the form offers that is not matched by
					name above -- "<" and ">" -- lands here, and the operator
					itself is interpolated. DB::escapeString(), which is what
					used to guard it, does nothing in an operator slot, so the
					submitted text could be any SQL at all. An allowlist is the
					only control that works here.
				*/
				$comp = pl_safe_comparison_operator($fcomp[$i], 'megapartyreport comparison');
				
					if ($field_data_type == 'date')
					{
						$field_value = pl_date_mogrify($fvalue[$i]);
					}
					
					else if ($field_data_type == 'time')
					{
						$field_value = pl_time_mogrify($fvalue[$i]);
					}

					else 
					{
						$field_value = $fvalue[$i];
					}
					
					$field_value = DB::escapeString($field_value);
				
				// Fail closed on an operator the form does not offer: no rows,
				// rather than a report that quietly ignored the filter.
				$sql .= (false === $comp)
					? " AND 0"
					: " AND $val$comp'$field_value'";
			}
		}
		/*
		else if (in_array($val, $special_fields))
		{
			if ('=' == $fcomp[$i])
			{
				// use IN() comparison
				// first add quotes around each comma-separated search item
				$val_array = explode(",", $fvalue[$i]);
				$quoted_vals = '';
				$y = 0;
				foreach($val_array as $x)
				{
					$field_value = _pl_input_filter($x, $plFields['cases'][$val]);
					
					if ($y > 0)
					{
						$quoted_vals .= ',';
					}
					
					$quoted_vals .= "'$field_value'";
					
					$y++;
				}
				
				
				$sql .= " AND (user_id IN($quoted_vals) OR cocounsel1 IN($quoted_vals) OR cocounsel2 IN($quoted_vals))";
			}
			
			else
			{
				// self-destruct if any operation other than '=' is attempted
				$sql .= "AND 0";
			}
		}
		*/
	}
	
	$i++;
}


if (strlen($users_list) > 0)
{
	$users_list = pl_process_comma_vals($users_list);
	//$users_list = substr($users_list, 0, (strlen($users_list) - 1));
	//$users_list = mysql_real_escape_string($users_list);
	
	if (strpos($showfields, 'activities.') === false)
	{
		$sql .= " AND (cases.user_id IN {$users_list} OR cases.cocounsel1 IN {$users_list} OR cases.cocounsel2 IN {$users_list})";
	}
	
	else
	{
		$sql .= " AND activities.user_id IN {$users_list}";
	}
}


/*	Build ORDER BY and GROUP BY clauses.

	The DB::escapeString() calls that used to sit on each of these four names
	are gone. All four are identifiers, so escaping them was a no-op; they are
	held to pl_safe_identifier() near the top of this file instead.
*/
if ($order_by)
{
	$sql .= " ORDER BY $order_by";
	
	if ($order_by2)
	{
		$sql .= ", $order_by2";
	}
}

// Build GROUP BY clause
if ($group_by)
{
	$sql .= " GROUP BY $group_by";
	
	if ($group_by2)
	{
		$sql .= ", $group_by2";
	}
}

/*	Build the LIMIT clause.

	$recordlimit reached the query with no escaping and no cast of any kind, so
	the row count could carry any SQL after it -- including INTO OUTFILE, which
	writes a file on the database server if the account has FILE privilege. A
	cast to int is the whole fix: a LIMIT is a number and nothing else.
*/
$recordlimit = (int) $recordlimit;

if ($recordlimit < 1)
{
	$recordlimit = 1000;
}

$sql .= " LIMIT $recordlimit";

$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());

$r->title = $report_title;
$r->display_row_count(true);

while ($row = DBResult::fetchRow($result))
{
	if (isset($row['open_date']))
	{
		$row['open_date'] = pl_date_unmogrify($row['open_date']);
	}

  if (isset($row['relation_code']))
  {
    $row['relation_code'] = pl_array_lookup($row['relation_code'], pl_menu_get('relation_codes'));
  }
	
	if (isset($row['close_date']))
	{
		$row['close_date'] = pl_date_unmogrify($row['close_date']);
	}
	
	if (isset($row['act_date']))
	{
		$row['act_date'] = pl_date_unmogrify($row['act_date']);
	}
	
	if (isset($row['act_time']))
	{
		$row['act_time'] = pl_time_unmogrify($row['act_time']);
	}

	if ($report_format != 'csv' && isset($row['number']))
	{
		$url_number = urlencode($row['number']);
		$row['number'] = "<a href=\"{$base_url}/search.php?s={$url_number}\">{$row['number']}</a>";
	}

	if ($report_format != 'csv' && isset($row['act_date']))
	{
		$row['act_date'] = "<a href=\"{$base_url}/activity.php?act_id={$row['act_id_deleteme']}\">{$row['act_date']}</a>";
	}
	
	if ($report_format != 'csv' && isset($row['act_time']))
	{
		$row['act_time'] = "<a href=\"{$base_url}/activity.php?act_id={$row['act_id_deleteme']}\">{$row['act_time']}</a>";
	}
	
	unset($row['act_id_deleteme']);
	$r->set_header(array_keys($row));
	$r->add_row($row);
}

if ($show_sql)
{
	$r->set_sql($sql);
}

$r->display();
exit();

?>
