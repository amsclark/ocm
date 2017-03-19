<?php

function red_flag($field_name = null, $field_value = null, $menu_array = null, $args = null)
{
	$flag_output = '';
	if(!is_null($field_value) && !is_array($field_value) && $field_value) {
	
		$field_value = str_replace(' ', '&nbsp;', $field_value);
		
		/*
		$flag_output .= ' &nbsp;<span style="white-space: nowrap; line-height: 25px; border: 1px solid #999999; padding: 2px 2px 0px;" class=thinborder>
						 <img width=16 height=16 src="images/redflag.gif" alt="red_flag" style="vertical-align:text-top;">&nbsp;&nbsp;';
		$flag_output .= "{$field_value}</span> ";
		*/
		
		$flag_output .=	"<div class=\"warnings\"><i class=\"material-icons\">check_circle</i>";
		$flag_output .=	"<span class=\"flag_label\">{$field_value}</span></div>";
		
		
	}
	
	return $flag_output;
}

?>
