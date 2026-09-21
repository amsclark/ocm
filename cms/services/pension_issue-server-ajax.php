<?php

/**********************************/
/* Pika CMS (C) 2008 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

chdir('..');
require_once('pika-danio.php');
pika_init();



$pension_issue = pl_grab_get('pension_issue');
$pension_issue = substr($pension_issue, 0, 2);

$safe_pension_issue = DB::escapeString($pension_issue);

$buffer = '';

$doc = new DOMDocument();
$problem_xml = $doc->createElement('pension_issues');
$problem_xml = $doc->appendChild($problem_xml);


$where_sql = '';
if (strlen($pension_issue) == 2)
{
	$where_sql .= " AND value LIKE '{$safe_pension_issue}%'";
}

/*	The pension sub-issue menu is optional add-on schema. No install or
	upgrade script creates menu_pension_sub_issue, so on a stock install the
	query below failed and this service answered every signed-in request with
	HTTP 500 and a text/html error page, to a caller that asked for text/xml.
	Answer with the empty list instead, which is the same document the query
	returns when no row matches. The reports that read the same two pension
	menus already guard themselves with pika_report_require_schema().
*/
if (pl_mysql_table_exists('menu_pension_sub_issue'))
{
	$sql = "SELECT value, label FROM menu_pension_sub_issue WHERE 1 {$where_sql} ORDER BY menu_order";
	$result = DB::query($sql);
	while ($row = DBResult::fetchRow($result)) {
		$problem_node = $doc->createElement('pension_issue');
		$problem_node = $problem_xml->appendChild($problem_node);
		/*	createElement() does not escape its value argument, so a menu
			label holding & or < wrote a document the caller cannot parse.
			The sibling services/problem-server-ajax.php already cleans
			both fields the same way.
		*/
		$node = $doc->createElement('value', pl_clean_html($row['value']));
		$node = $problem_node->appendChild($node);
		$node = $doc->createElement('label', pl_clean_html($row['label']));
		$node = $problem_node->appendChild($node);
	}
}


$buffer = $doc->saveXML();
header('Content-type: text/xml');
pika_exit($buffer);
?>
