<?php

/*	The mirror of red_flag for a message that is not an error.

	Every status message in this application went through red_flag, which
	draws a warning badge, so "Password updated successfully" arrived in the
	same colour as "Error: New password cannot be blank". A confirmation that
	looks like a failure is a message the user has to read twice to act on.

	The signature and the &nbsp; substitution match red_flag exactly so the
	two can be swapped at a call site without any other change.
*/
function success_flag($field_name = null, $field_value = null, $menu_array = null, $args = null)
{
	$flag_output = '';
	
	if(!is_null($field_value) && !is_array($field_value) && $field_value) {
	
		$field_value = str_replace(' ', '&nbsp;', $field_value);
		
		$flag_output .=	"<span class=\"label label-success flag\"><i class=\"icon-ok icon-white\"></i></span>&nbsp;";
		$flag_output .=	"<span class=\"flag_label\">{$field_value}</span>";
		
	}
	
	return $flag_output;
}

?>
