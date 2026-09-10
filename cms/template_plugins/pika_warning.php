<?php

function pika_warning($field_name = null, $field_value = null, $menu_array = null, $args = null)
{
	/*if (!is_array($menu_array))
	{
		$menu_array = array();
	}
	if(is_array($field_value)){
		$field_value = null;
	}
	if(!is_array($args)) {
		$args = array();
	}*/
	
	require_once('app/lib/pikaWarning.php');
	$warning = pikaWarning::getInstance();
	$warnings = $warning->getWarnings();
	
	$warning_output = '';
	
	/*	Answering the TODO below: yes, this is tied to display_errors.
		
		The collected notices name absolute server paths and line numbers, and
		they were rendered into the page body for every authenticated user --
		which php.ini's display_errors setting does not stop, because the
		notices come back out of this application's own collector rather than
		PHP's output. So on a correctly configured server holding client data,
		the one place error detail was still on show was here.
		
		The notices are on the page or not on the page; nothing is lost by
		leaving them out, because pl_error_handler() has already written each
		one to the server log where an operator can read it.
	*/
	if (!pl_is_debug_mode()) {
		return $warning_output;
	}
	
	// Check to see if warnings were generated - otherwise nothing to display
	if(!is_array($warnings) || (is_array($warnings) &&  count($warnings) < 1)) {
		return $warning_output;
	}
	$num_warnings = count($warnings);
	$base_url = pl_settings_get('base_url');
	
	// At least one warning exists (TODO - tie this to display_errors?)
	$warning_output .= "<div id='warning_link'><a href={$base_url} onclick='toggleWarnings();return false;'>PHP Warnings [{$num_warnings}]</a></div>";
	$warning_output .= "<div id='warning_list' style='display: none'>";
	$i = 1;
	foreach ($warnings as $val) {
		$warning_level = $val[0];
		switch ($warning_level) {
			case E_WARNING: // 2
				$warning_level = 'E_WARNING [2]';
	    		break;
			case E_PARSE: // 4
				$warning_level = 'E_PARSE [4]';
	    		break;
			case E_NOTICE: // 8
				$warning_level = 'E_NOTICE [8]';
	    		break;
			case E_STRICT: // 2048
				$warning_level = 'E_STRICT [2048]';
	    		break;
			case E_RECOVERABLE_ERROR: // 4096
				$warning_level = 'E_RECOVERABLE_ERROR [4096]';
	    		break;	
		}
		/*	The message carries the offending value: "Undefined array key
			<name>" quotes the key, and a key can come from the query string.
			Escaped, because this block is markup and the template engine
			escapes nothing.
		*/
		$warning_output .= $i++ . "/{$num_warnings} " . pl_html_escape($warning_level) . ": "
			. pl_html_escape($val[1]) . " - File: " . pl_html_escape($val[2])
			. " - Line: " . pl_html_escape($val[3]) . "<br/>";
	}
	$warning_output .= "</div>\n";
	$warning_output .= pikaTempLib::plugin('javascript','toggleDiv.js');
	$warning_output .= pikaTempLib::plugin('javascript','pika_warning.js');
	
	return $warning_output;
}

?>