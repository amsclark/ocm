<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

function mysql_query($sql)
{
	return DB::query($sql);
}

function mysql_real_escape_string($str)
{
	return DB::escapeString($str);
}

function mysql_fetch_assoc($result)
{
	return DBResult::fetchRow($result);
}

function mysql_num_rows($result)
{
	return DBResult::numRows($result);
}

/*	Legacy error accessor. DB.php's non-mysqli path calls mysql_error(), and so
	do the two reports that still use mysql_query() -
	cms/reports/pension_grant/report.php and
	cms/reports/client_location/report.php - on their error paths. PHP 7 removed
	the function and nothing here defined it, so an SQL error in those reports
	was a fatal about an undefined function instead of the message the report
	was trying to print. Route it to DB::error() like the rest of this shim.
*/
if (!function_exists('mysql_error'))
{
	function mysql_error()
	{
		return DB::error();
	}
}
