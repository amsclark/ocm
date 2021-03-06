<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('pl.php');


/**
* class plBase
* 
* Implements methods to interact with DB as a DB Table Gateway pattern
* Child classes extend this class for individual tables (ex. pikaCase => cases)
*
* @author Aaron Worley <amworley@pikasoftware.com>;
* @version 1.0
* @package Danio
*/
class plBase
{
	// Container array for data fields.
	protected $values = array();  
	// Flagged if the database record needs to be updated during destruction.
	public $is_modified = false;  // Needed by plSettings and other alt. storage classes.
	// Flagged if the database record needs to be created during destruction.
	public $is_new = false;
	
	// Child classes may need to access these, so they are protected and not private.
	protected $db_table = 'noname';
	protected $db_table_id_column = '';  // Name of table's primary key.
	
	protected $use_next_id_counter = true;  // Autogenerate id value on null from counters table
	
	private $db_table_columns = array();  // Array of column names, autogenerated.
	private $db_table_default_values = array();  // Array of default column values, autogen'ed.
	
	protected $last_query = '';
	
	
	public function __construct($id = null)
	{
		pl_mysql_init() or trigger_error('Database Connection Failed');
		$this->tableInit();
		
		if (is_null($id) || strlen($id) < 1)
		{
			
			/*	Mark this as a new record.
			
				Then determine the record ID.  Don't trigger an error while
				the tables are locked, don't want them staying locked.
				
				Then assign any default values for this table.
			*/
			$this->is_new = true;
						
			foreach ($this->db_table_columns as $key => $val)
			{
				$this->values[$key] = null;
			}
			
			$this->values = array_merge($this->values, $this->db_table_default_values);
			if($this->use_next_id_counter) 
			{
				$this->values[$this->db_table_id_column] = self::getNextID($this->db_table);
			}
		}
		else
		{
			$clean_id = mysql_real_escape_string($id);
			$sql = "SELECT * FROM {$this->db_table} WHERE {$this->db_table_id_column} = '{$clean_id}' LIMIT 1";
			$result = mysql_query($sql) or trigger_error("SQL: " . $sql . " Error: " . mysql_error());
			$this->last_query = $sql;
			if (mysql_num_rows($result) < 1)
			{
				trigger_error("{$this->db_table_id_column} = '{$clean_id}'; No such record found.");
				return false;
			}
			
			else 
			{
				$row = mysql_fetch_assoc($result);
				$this->loadValues($row);
			}
		}
		return true;
	}
	
	
	public function __get($value_name)
	{
		return $this->getValue($value_name);
	}
	
	public function getValue($name) { 
		if (array_key_exists($name, $this->db_table_columns)) {
			return $this->values[$name];
		} else {
			return false;
		}
	}
	public function getValues() { return $this->values; }
	
	
	public function __set($value_name, $value)
	{
		// Note.  This is bypassed by PHP 5 if a variable
		// already exists named $this->value_name.
		return $this->setValue($value_name,$value);
	}
	
	public function setValue($name, $value){
		if (array_key_exists($name, $this->db_table_columns))
		{
			$this->values[$name] = $value;
			$this->is_modified = true;
			return true;
		} else {
			return false;	
		}
	}
	
	public function setValues($a)
	{
		$success_status = true;
		if(is_array($a) && count($a) > 0) {
			foreach ($a as $key => $val)
			{
				if(!$this->setValue($key,$val)){$success_status = false;}
			}
		}
		return $success_status;
	}
	
	
	public function save()
	{
		$sql = '';
		
		if ($this->is_new == true)
		{
			$sql = $this->tableAutosqlInsert($this->values);
			mysql_query($sql) or trigger_error("SQL: " . $sql . " Error: " . mysql_error());
			$this->last_query = $sql;
			$this->is_new = false;
			$this->is_modified = false;
			return mysql_affected_rows();
		}
		else if ($this->is_modified == true)
		{
			$sql = $this->tableAutosqlUpdate($this->values);
			mysql_query($sql) or trigger_error("SQL: " . $sql . " Error: " . mysql_error());
			$this->last_query = $sql;
			$this->is_modified = false;
			return mysql_affected_rows();
		}
		else 
		{
			return true;
		}
	}
	
	// Used only by child classes to load initial values.
	protected function loadValues($a)
	{
		if (is_array($a))
		{
			$this->values = array_merge($this->values, $a);
			return true;
		}
		
		else
		{
			trigger_error("\"{$a}\" is not an array.");
			return false;
		}
	}

	/**
	 * public function delete()
	 * 
	 * Deletes record specified by primary key from Database
	 *
	 * @return boolean - true
	 */
	public function delete()
	{
		$this->is_modified = false;
		$this->is_new = false;
		
		$sql = "DELETE FROM {$this->db_table} 
				WHERE `{$this->db_table_id_column}` = '{$this->values[$this->db_table_id_column]}' 
				LIMIT 1;";
		mysql_query($sql) or trigger_error("SQL: " . $sql . " Error: " . mysql_error());
		$this->last_query = $sql;
		return true;
	}
	
	/**
	 * protected function dataBuildField
	 *
	 * Any field that is NULL, or any zero-length string,
	 * should be assigned the value NULL.
	 * 
	 * We don't want zero-length strings in the database, because
	 * they screw up "WHERE x IS NULL" SQL statements.  Additionally,
	 * a numeric field cannot be assigned a zero length string in MySQL;
	 * it will instead assume the value 0.
	 * 
	 * This may be obvious, but note that, in cases where a blank text
	 * string is desired, but NOT NULL is specified for that column, you'll
	 * need to add a whitespace character to the field before passing the
	 * data on to dataBuildField().
	 * 
	 * @param string $field_name
	 * @param string $field_value
	 * @param string $type
	 * @return string field and value pair in SQL formatting (ex. case_id='4')
	 */
	protected function dataBuildField($field_name,$field_value,$type) {
		
		$numeric_types = array(	'tinyint','smallint','mediumint','int','bigint',
								'decimal','float','double','real',
								'bit','bool','serial');
		$sql = '';
		if(is_null($field_name) || strlen($field_name) < 1) {
			// Make sure field_name is supplied if not
			// return false
			return false;
		}
		if(is_null($field_value) || strlen($field_value) < 1)
		{
			$sql = $field_name." = NULL";
		}
		else 
		{
			switch (strtolower($type)) {
				case 'tinyint':
				case 'smallint':
				case 'mediumint':
				case 'int':
				case 'bigint':
				case 'decimal':
				case 'float':
				case 'double':
				case 'real':
				case 'bit':
				case 'bool':
				case 'serial':
					if(is_numeric($field_value))
					{	// Need to strip whitespace as it will
						// not trigger is_numeric to be false
						$sql = $field_name." = '".trim($field_value)."'";
					}
					else
					{	// Not a valid number and cannot put
						// blank string in number type field
						$sql = $field_name." = NULL";
					}
					break;
				case 'date':
					$field_value = pl_date_mogrify($field_value);
					$safe_field_value = mysql_real_escape_string($field_value);
					$sql = "{$field_name} = '{$safe_field_value}'";
					break;
				case 'time':
					$field_value = pl_time_mogrify($field_value);
					$safe_field_value = mysql_real_escape_string($field_value);
					$sql = "{$field_name} = '{$safe_field_value}'";
					break;
				case 'timestamp':
					$safe_field_value = mysql_real_escape_string($field_value);
					if(strpos($field_value,'CURRENT_TIMESTAMP') === false)
					{  // Only need quotes if timestamp provided - variables cannot be quoted
						$safe_field_value = "'{$safe_field_value}'";
					}
					$sql = "{$field_name} = {$safe_field_value}";
					break;
				default:
					$safe_field_value = mysql_real_escape_string($field_value);
					$sql = "{$field_name} = '{$safe_field_value}'";
					break;
			}
		}
		
		
		return $sql;
	}
	
	/**
	 * protected function dataBuildFieldList()
	 * 
	 * This function iterates through the db_table_columns and generates
	 * the appropriate SQL friendly key=value pairs for INSERT and UPDATE
	 * queries.  Calls dataBuildField for each value to handle empty strings
	 * and escaping
	 *
	 * @param array $data
	 * @return string of key=value pairs separated by commas in SQL
	 * format (ex value1=NULL,value2='2',... etc)
	 */
	protected function dataBuildFieldList($data,$excluded_fields = array()) {
		$sql = '';
		if(!is_array($excluded_fields)) {
			$excluded_fields = array();
		}
		$tmp_data = array();
		foreach ($this->db_table_columns as $key => $field_property)
		{
			$field_sql = '';
			// make sure the data's column name is valid
			if (array_key_exists($key, $data) && !in_array($key,$excluded_fields))
			{
				$field_sql = $this->dataBuildField($key,$data[$key],$field_property['Type']);
				if($field_sql !== false) {
					$tmp_data[] = $field_sql;
				} 
			}
		}
		$sql = implode(', ',$tmp_data);
		return $sql;
	}
	
	
	/**
	 * public static describeTableDB
	 * 
	 * Returns output of MySQL DESCRIBE query
	 *
	 * @param string $db_table - name of database table
	 * @return $result - MySQL result set
	 */
	public static function describeTableDB($db_table)
	{
		if(strlen($db_table) > 0) 
		{
			$safe_db_table = mysql_real_escape_string($db_table);
			$sql = "DESCRIBE {$safe_db_table};";
			$result = mysql_query($sql) or trigger_error("SQL: " . $sql . " Error: " . mysql_error());
			return $result;
		}
		else 
		{
			trigger_error('No table name specified to plBase::describeTableDB');
		}
	}
	
	/**
	 * public static describeTable
	 * 
	 * Returns output of MySQL DESCRIBE query as an
	 * associative array keyed by name of field
	 *
	 * @param string $db_table - name of database table
	 * @return array $describe_array 
	 */
	public static function describeTable($db_table)
	{
		$describe_array = array();
		
		$result = plBase::describeTableDB($db_table);
		while ($row = mysql_fetch_assoc($result)) {
			$describe_array[$row['Field']] = $row;
		}
		
		return $describe_array;
	}
	
	/**
	 * private function tableInit()
	 * 
	 * Builds db_table_columns and db_table_default_values with data 
	 * from SQL DESCRIBE query
	 *
	 * @return boolean true
	 */
	private function tableInit()
	{
		$db_table_columns = array();
		$result = plBase::describeTableDB($this->db_table);
		
		while ($row = mysql_fetch_assoc($result))
		{
			$column_row = array();
			//$column_row['Field'] = $row['Field'];
			$column_row['Key'] = $row['Key'];
			if ($row['Key'] == 'PRI' && strlen($this->db_table_id_column) < 1)
			{	// Set primary key
				$this->db_table_id_column = $row['Field'];
			}
			// Determine the Type and Length of the Field
			if(strpos($row['Type'],'(') === false) 
			{	// Fieldname w/o Lenght contstraint (ie. Date/Time[stamp] etc)
				$column_row['Type'] = $row['Type'];
				$column_row['Length'] = '';
			}
			else 
			{	// Fieldname in "Name(Length)" Format
				$type_array = explode('(',$row['Type']);
				$column_row['Type'] = $type_array[0];
				$column_row['Length'] = str_replace(')','',$type_array[1]);
			}
			$column_row['Null'] = false;
			if($row['Null'] == 'YES') 
			{
				$column_row['Null'] = true;
			}
			if (!is_null($row['Default']) && '' != $row['Default'] && 'PRI' != $row['Key'])
			{	// Initialize the defaults table for merge w/ data array
				$this->db_table_default_values[$row['Field']] = $row['Default'];
			}
			//$column_row['Extra'] = $row['Extra'];
			
			$db_table_columns[$row['Field']] = $column_row;
		}
			
		$this->db_table_columns = $db_table_columns;
		return true;
	}
	
	
	/**
	 * public function getTableColumns
	 *
	 * Returns private db_table_columns array containing schema properties
	 * of current table keyed by field name
	 * 
	 * @return array
	 */
	public function getTableColumns()
	{
		return $this->db_table_columns;
	}
	
	/**
	 * public getTableDefaults
	 * 
	 * Returns array of table fields that have default values assigned
	 * in the database keyed by field name.
	 *
	 * @return array
	 */
	public function getTableDefaults()
	{
		return $this->db_table_default_values;
	}
	
	/**
	 * public getLastQuery
	 * 
	 * Returns the last SQL query run (stored in $last_query)
	 *
	 * @return string
	 */
	public function getLastQuery()
	{
		return $this->last_query;
	}
	
	/**
	 * private function tableAutosqlUpdate()
	 * 
	 * Builds SQL UPDATE statement tailored to the current table
	 *
	 * @param array $data
	 * @return string - The completed SQL Update statement
	 */
	private function tableAutosqlUpdate($data)
	{
		if(!is_array($data)) 
		{
			trigger_error('Invalid data array supplied to tableAutosqlUpdate');
		}
		$primary_key = $this->db_table_id_column;
		if(strlen($primary_key) == 0 || !$data[$primary_key]) 
		{
			trigger_error("Value for primary key is missing");
		}
		
		
		$sql = "UPDATE {$this->db_table} SET ";
		$sql .= $this->dataBuildFieldList($data,array($primary_key));
		$sql .= " WHERE {$primary_key}='{$data[$primary_key]}'";
		$sql .= ' LIMIT 1;';
		
		return $sql;
	}
	
	/**
	 * private function tableAutosqlInsert()
	 *
	 * * Builds SQL INSERT statement tailored to the current table
	 * 
	 * @param array $data
	 * @return unknown
	 */
	private function tableAutosqlInsert($data)
	{
		if(!is_array($data)) 
		{
			trigger_error('Invalid data array supplied to tableAutosqlUpdate');
		}
		$primary_key = $this->db_table_id_column;
		if(strlen($primary_key) == 0 || !$data[$primary_key]) 
		{
			trigger_error("Value for primary key is missing");
		}
		
		$sql = "INSERT {$this->db_table} SET ";
		$sql .= $this->dataBuildFieldList($data,array());
		$sql .= ";";
		
		return $sql;
	}
	
	
	/**
	 * public static getNextID
	 * 
	 * Returns next id value from counters table.
	 *
	 * @param string $sequence
	 * @return int $next_id
	 */
	public static function getNextID($sequence)
	{
		$safe_sequence = mysql_real_escape_string($sequence);
		$next_id = null;
		
		$sql = "LOCK TABLES counters WRITE";
		mysql_query($sql) or trigger_error("SQL: " . $sql . ' Error: ' . mysql_error());
		$sql = "SELECT count 
				FROM counters 
				WHERE 1 AND id = '{$safe_sequence}' 
				LIMIT 1";
		$result = mysql_query($sql) or trigger_error("SQL: " . $sql . ' Error: ' . mysql_error());
		
		if (mysql_num_rows($result) < 1)
		{
			$sql = "INSERT INTO counters SET id = '{$safe_sequence}', count = '1'";
			mysql_query($sql) or trigger_error("SQL: " . $sql . ' Error: ' . mysql_error());
			$next_id = 1;
		}
	
		else
		{
			$row = mysql_fetch_assoc($result);
			$next_id = $row['count'] + 1;
			$sql = "UPDATE counters SET count = count + '1' WHERE id = '{$safe_sequence}' LIMIT 1";
			mysql_query($sql) or trigger_error("SQL: " . $sql . ' Error: ' . mysql_error());
			
		}
	
		$sql = "UNLOCK TABLES";
		mysql_query($sql) or trigger_error("SQL: " . $sql . ' Error: ' . mysql_error());
		return $next_id;
	}
	
	
	public function valueExists($name)
	{
		$this->tableInit();
		return array_key_exists($name, $this->values);
	}
}

?>