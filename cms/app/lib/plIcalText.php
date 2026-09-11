<?php

/*	plIcalText.php - text escaping for the iCalendar feeds under cms/services/.
	
	Its own file, rather than another function in pl.php, so that both feeds
	share one copy of the rule.  cms/services/calendar.php and
	cms/services/calendar-4.php each carried a local ical_text_mogrify() and
	the two had already started to drift.
*/

if (!function_exists('pl_ical_text_escape'))
{
	/*	Escape a value for an iCalendar TEXT property (RFC 5545 section
		3.3.11).
		
		The old ical_text_mogrify() dropped CR and turned LF into the literal
		two characters \n.  The newline half is the part that matters for
		safety - a raw line ending is the only way a value can close its own
		property line and open a forged one - but it is not the only character
		the spec reserves:
		
		  * Comma and semicolon went out raw.  Case notes are prose and most
		    of them contain a comma.  An unescaped comma in a TEXT value is
		    malformed, and a reader that parses the property as a value list
		    truncates the note at the first one.  ALARM is semicolon
		    delimited, so an unescaped semicolon there added a bogus field.
		
		  * Backslash went out raw, so a note mentioning C:\temp arrived
		    mangled.
		
		  * A lone CR was deleted instead of folded, silently joining two
		    lines into one word.  Old Mac line endings and some paste sources
		    still produce them.
		
		Order matters.  Backslash is escaped first, or the backslashes this
		function adds get escaped a second time and the reader sees \\, where
		it should see a comma.
		
		@param		string		$value		Raw text.
		@return		string					Escaped for an iCalendar TEXT value.
	*/
	function pl_ical_text_escape($value)
	{
		if (is_null($value))
		{
			return '';
		}
		
		$s = (string) $value;
		$s = str_replace('\\', '\\\\', $s);
		$s = str_replace(array(';', ','), array('\\;', '\\,'), $s);
		
		/*	Every line ending becomes the literal \n the spec calls for.  CRLF
			is handled before the bare cases so that it yields one escape and
			not two.
		*/
		$s = str_replace(array("\r\n", "\r", "\n"), '\\n', $s);
		
		return $s;
	}
}

?>
