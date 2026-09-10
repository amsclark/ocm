<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

class DB
{
	protected static $link = null;
	protected static $mysqli_mode = PIKACMS_MYSQLI_MODE;

	protected function __construct()
	{
		//
	}

	protected function __clone()
	{
		//
	}

	public static function error()
	{
		if (self::$mysqli_mode) {
			/*	error() is called from the "or trigger_error(... DB::error())"
				idiom all over the tree, which includes the paths that run
				when the connection itself failed. mysqli_error(null) is a
				TypeError on PHP 8, so the report of the real problem died
				inside the reporting of it and the page returned nothing at
				all. Say what happened instead.
			*/
			if (!self::$link) {
				return 'No MySQLi connection established.';
			}
			
			return mysqli_error(self::$link);
		}

		else {
			return mysql_error();
		}

	}

	/*	Null is escaped as the empty string rather than being handed to the
		driver. Callers all over the tree escape a filter value that is simply
		absent, and passing null to a string parameter is a deprecation on
		PHP 8.1 and a TypeError on PHP 9 -- a fatal on any page with an
		unset filter. The value the driver returned for null was the empty
		string anyway, so behaviour is unchanged.
	*/
	public static function escapeString($str)
	{
		if (is_null($str)) {
			$str = '';
		}
		
		if (self::$mysqli_mode) {
			return mysqli_real_escape_string(self::$link, $str);
		}

		else {
			return mysql_real_escape_string($str);
		}
	}

	public static function affectedRows()
	{
		if (self::$mysqli_mode) {
			return mysqli_affected_rows(self::$link);
		}

		else {
			return mysql_affected_rows();
		}
	}

	public static function init($host, $db_name, $user, $password)
	{
		static $connection_is_live = false;

		if (self::$mysqli_mode) {
			self::$link = mysqli_connect($host, $user, $password, $db_name);
			return true;
		}

		else {
			/*  Don't trigger any errors if the connection fails, just return false
        		and let the app. code handle the error.
    			*/
			if (false == $connection_is_live)
			{
				$status = mysql_connect($host, $user, $password);

				if ($status !== false)
				{
					$connection_is_live = mysql_select_db($db_name) or trigger_error(mysql_error());
				}
			}

			return $connection_is_live;
		}
	}

	public static function query($sql)
	{
		if (self::$mysqli_mode) {
			return mysqli_query(self::$link, $sql);
		}

		else {
			return mysql_query($sql);
		}
	}

	public static function preparedQuery($sql, $params)
	{
		if (!self::$mysqli_mode) {
			throw new Exception("Prepared statements are only supported in MySQLi mode.");
		}

		$stmt = mysqli_prepare(self::$link, $sql);
		if ($stmt === false) {
			throw new Exception("Failed to prepare the statement: " . self::error());
		}

		if ($params) {
			$types = str_repeat('s', count($params)); // Assuming all parameters are strings
			$stmt->bind_param($types, ...$params);
		}

		if (!$stmt->execute()) {
			throw new Exception("Failed to execute the statement: " . self::error());
		}

		/*	get_result() returns false for a statement that produces no result
			set, which is every INSERT, UPDATE and DELETE. Callers read that
			false as a failed write: pl_audit() logged "pl_audit insert failed"
			for every audit record it successfully wrote, so the error log said
			auditing was broken on a deployment where it was working. Report
			success instead, and leave the real failures to the throws above.
		*/
		if (0 === $stmt->field_count) {
			return true;
		}

		return $stmt->get_result();
	}
}