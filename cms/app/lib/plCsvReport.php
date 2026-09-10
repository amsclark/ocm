<?php

require_once('plCsvReportTable.php');

/**
* plCsvReport - Creates an CSV report display containing one or more instances
* of plCsvReportTable.  Creates first table automatically - for legacy support.
*
* @author Aaron Worley <amworley@pikasoftware.com>;
* @version 1.0
* @package Danio
*/
class plCsvReport
{
	public $tables = array();
	public $current_table_index;
	public $title = '';
	public $parameters = array();
	
	public function __construct(){
		$this->title = 'A Report';
		// 2013-08-13 AMW - Removed =& for compatibility with PHP 5.3.
		$this->tables[] = new plCsvReportTable();
		$this->current_table_index = '0';
	}
	
	public function add_table() {
		// 2013-08-13 AMW - Removed =& for compatibility with PHP 5.3.
		$this->tables[] = new plCsvReportTable();
		$this->current_table_index += 1;
	}
	
	public function add_row($a = array()) {
		$this->tables[$this->current_table_index]->add_row($a);
	}
	
	public function add_parameter($name,$parameter) {
		$parameters = $this->parameters;
		$parameters[] = array('name'=>$name,'param'=>$parameter);
		$this->parameters = $parameters;
	}
	
	public function set_sql($sql) {
	}
	
	public function set_header($a = array()) {
		$this->tables[$this->current_table_index]->set_header($a);
	}
	
	public function set_footer($footer = '') {}
	
	public function set_title($title) {
		$this->title = strip_tags($title);
	}
	
	public function set_table_title($title) {
		$this->tables[$this->current_table_index]->set_title($title);
	}
	
	public function display_row_count($value) {
	}
	
	public function display(){
		/*	The report title and the filter-parameter lines are the two
			lines of the export that plCsvReportTable never sees, and
			they were assembled here by hand with addslashes(). Same pair
			of defects the table class had:
			
			  - addslashes() emits \" where CSV requires "". PHP's own
			    str_getcsv() treats that as an escape, which is why it
			    reads as cosmetic, but RFC 4180 has no backslash escape,
			    so Excel, LibreOffice and Sheets end the field at that
			    quote. A filter value carrying a quote and a comma opens
			    a fresh cell, and that cell is free to begin '=' -- which
			    is how a filter value becomes a live formula in spite of
			    the literal "Name: " sitting in front of it. It also
			    backslashes apostrophes, so every O'Brien left in an
			    export with a stray backslash in it.
			  - Neither line ran the formula guard. Report titles are
			    mostly literals under cms/reports, but the filter
			    parameters are whatever the user typed into the report
			    form.
			
			Written through plCsvReportTable::format_csv_cell() rather
			than a second copy of the quoting rules, so the preamble and
			the rows cannot drift apart again. That also keeps the
			one-column-plus-trailing-comma shape these two lines have
			always had.
		*/
		$writer = count($this->tables)
			? $this->tables[0]
			: new plCsvReportTable();
		
		$buffer = $writer->format_csv_cell($this->title) . "\n";
		foreach ($this->parameters as $parameter) {
			if(isset($parameter['name']) && $parameter['name'] && isset($parameter['param'])) {
				$buffer .= $writer->format_csv_cell(
					$parameter['name'] . ': ' . $parameter['param']) . "\n";
			}
		}
		
		for ($i=0;$i<count($this->tables);$i++) {
			$buffer .= $this->tables[$i]->build(); 	
		}
		
		header("Pragma: public");
		header("Cache-Control: cache, must-revalidate");
		header("Content-type: application/force-download");
		header("Content-Type: text/x-comma-separated-values");
		
		/*	strlen(), not mb_strlen(). Content-Length counts bytes; on a
			build where mbstring's internal encoding is UTF-8, mb_strlen()
			counts characters, so a report holding any non-ASCII text -- an
			accented client name, a curly quote pasted out of a document --
			declared a length shorter than the body and the browser cut the
			download off at that many bytes.
		*/
		if (pl_settings_get("enable_compression") == false)
		{
			header("Content-Length: " . strlen($buffer));
		}

		// AMW 2013-10-16 - Workaround for new Chrome/CSV behavior.
		if (strpos($_SERVER['HTTP_USER_AGENT'], 'Chrome') !== false  || 
				strpos($_SERVER['HTTP_USER_AGENT'], 'Safari') !== false)
		{
		    header("Content-Disposition: attachment; filename=\"{$this->title}.csv\"");
		}
		
		else
		{
			header("Content-Disposition: inline; filename=\"{$this->title}.csv\"");
		}
		
		echo $buffer;
		exit();
	}
}

?>
