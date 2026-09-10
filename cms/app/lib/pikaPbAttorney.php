<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('plBase.php');

/**
* Something.
*
* @author Aaron Worley <amworley@pikasoftware.com>;
* @version 1.0
* @package Danio
*/
class pikaPbAttorney extends plBase
{


	function __construct($id = null)
	{
		$this->db_table = 'pb_attorneys';
		parent::__construct($id);
	}
	
	/*	Escape the columns that the two pro bono attorney list screens render
		raw. pb_attorneys.php and assign_pba.php both walk the same result set
		into the same flex_row markup, so the escaping belongs here rather than
		in each of them.
		
		atty_name is not touched: the two screens build it differently, one as
		a link and one as a form, and each escapes the name where it builds it.
		
		pl_text_address() joins the address columns with newlines and emits no
		markup of its own, so escaping the finished string is safe. The
		text_address template plugin in html mode is a different function that
		interleaves <br/> with the values, and escaping that result would show
		a literal "<br/>".
	*/
	public static function decorateListRow($row)
	{
		$row['atty_address'] = pl_html_escape_label(pl_text_address($row));
		$row['last_case'] = pl_date_unmogrify(isset($row['last_case']) ? $row['last_case'] : null);
		
		foreach (array('firm','phone_notes','email','county','languages','practice_areas','notes') as $col)
		{
			if (isset($row[$col]))
			{
				$row[$col] = pl_html_escape_label($row[$col]);
			}
		}
		
		return $row;
	}
	
	public static function getPbAttorneyDB(){
		$sql = "SELECT * FROM pb_attorneys WHERE 1";
		$result = DB::query($sql) or trigger_error('SQL: ' . $sql . ' Error: ' . DB::error());
		return $result;
	}

	public static function getPbAttorneys($filter, &$row_count, $order_field='',
	$order='ASC', $first_row='0', $list_length='100') {
		$sql_filter = $limit_sql = $order_sql = "";

		// Filter elements need to be escaped
		foreach ($filter as $key => $val)
		{
			$filter[$key] = DB::escapeString($val);
		}

		if (isset($filter['county']) && $filter['county']){
			$sql_filter .= " AND county LIKE '%{$filter['county']}%'";
		}

		if (isset($filter['languages']) && $filter['languages']){
			$sql_filter .= " AND languages LIKE \"%{$filter['languages']}%\"";
		}

		if (isset($filter['practice_areas']) && $filter['practice_areas']){
			$sql_filter .= " AND practice_areas LIKE '%{$filter['practice_areas']}%'";
		}

		if (isset($filter['last_name']) && $filter['last_name']){
			$sql_filter .= " AND last_name LIKE '%{$filter['last_name']}%'";
		}
		// ?order_field= from pb_attorneys.php and assign_pba.php.
		$order = pl_safe_sort_direction($order);
		if ($order_field && $order){
			if ('atty_name' == $order_field){
				$order_sql = " ORDER BY last_name {$order}, first_name {$order}";
			} else {
				$order_sql = pl_safe_order_by($order_field, $order, 'pro bono list sort column');
			}
		}
		if ($first_row && $list_length){
			$limit_sql = " LIMIT " . (int) $first_row . ", " . (int) $list_length;
		} elseif ($list_length){
			$limit_sql = " LIMIT " . (int) $list_length;
		}



		$sql = "SELECT count(*) as nbr
				FROM pb_attorneys 
				WHERE 1 $sql_filter";

		$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		if(DBResult::numRows($result) == 1) {
			$row = DBResult::fetchRow($result);
			$row_count = $row['nbr'];
		} else { $row_count = 0; }
		
		$sql = "SELECT * 
				FROM pb_attorneys 
				WHERE 1 $sql_filter $order_sql $limit_sql";

		$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		return $result;
	}
	
	public static function getPbAttorneyArray($filter = array()) {
		$row_count = 0;
		$pba_array = array();
		$result = self::getPbAttorneys($filter,$row_count,'name');
		
		while ($row = DBResult::fetchRow($result))
		{
			$pba_array[$row['user_id']] = "{$row['last_name']}, {$row['first_name']} {$row['middle_name']} {$row['extra_name']}";
		}
		return $pba_array;
	}
	
	
}


?>