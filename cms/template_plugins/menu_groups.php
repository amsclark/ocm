<?php


function menu_groups($field_name = null, $field_value = null, $menu_array = null, $args = null)
{
	
	if (!is_array($menu_array))
	{
		$menu_array = array();
	} else {
		$tmp_menu_array = array();
		$menu_array_groups = $menu_array;
		// parse back into menu array of values for field value comparisons
		foreach ($menu_array as $group_heading => $group_array) {
			foreach ($group_array as $key => $val) {
				$tmp_menu_array[$key] = $val;
			}
		}
		$menu_array = $tmp_menu_array;
	}
	if(is_array($field_value)){
		$field_value = null;
	}
	
	if(!is_array($args)) {
		$args = array();
	}
	
	$def_args = array(
		// STD Directives
		'name' => $field_name,
		'id' => $field_name,
		'class' => 'plmenu',
		'tabindex' => '1',
		'disabled' => false,
		// JS Directives
		'onfocus' => '', 
		'onblur' => '', 
		'onchange' => '',
		// Data Directives
		'noblank' => false
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	// Begin building menu
	
	$menu_output = '';
	$menu_output .= "<select ";
	
	$menu_output .= "name=\"" . pl_html_escape($temp_args['name']) . "\" ";
	$menu_output .= "id=\"" . pl_html_escape($temp_args['id']) . "\" ";
	$menu_output .= "class=\"" . pl_html_escape($temp_args['class']) . "\" ";
	$menu_output .= "tabindex=\"" . pl_html_escape($temp_args['tabindex']) . "\" ";
	if($temp_args['disabled']) {
		$menu_output .= "disabled ";
	}
	
	if($temp_args['onfocus'] != '') {
		$menu_output .= "onFocus=\"" . pl_html_escape($temp_args['onfocus']) . "\" ";	
	} if($temp_args['onblur'] != '') {
		$menu_output .= "onBlur=\"" . pl_html_escape($temp_args['onblur']) . "\" ";
	} if($temp_args['onchange'] != '') {
		$menu_output .= "onChange=\"" . pl_html_escape($temp_args['onchange']) . "\" ";
	}
	
	$menu_output .= ">\n";
	
	if($temp_args['noblank']) {
		if(is_null($field_value) || strlen($field_value) < 1) {  // Enter blank if and only if value is blank
			$menu_output .= "<option selected value=\"\">&nbsp;</option>\n";
		}
	} else { // Blanks are shown - Check if field is blank to mark as selected
		$selected = '';
		if(is_null($field_value) || strlen($field_value) < 1) {
			$selected = 'selected';
		}
		$menu_output .= "<option {$selected} value=\"\">&nbsp;</option>\n";
	}
	
	if (!is_null($field_value) && !isset($menu_array[$field_value]) && strlen($field_value) > 0) {
		$menu_output .= "<option selected value=\"" . pl_html_escape($field_value) . "\">" . pl_html_escape($field_value) . "</option>\n";
	}
	
	// catch any cases where no menu data is available
	if (count($menu_array) < 1)
	{
		$menu_output .= "<option value=\"\">No Menu Available</option>\n";
	}
	
	foreach ($menu_array_groups as $key => $group) {
		$menu_output .= "<optgroup label=\"" . pl_html_escape($key) . "\">\n";
		foreach ($group as $key => $label) {
			$selected = '';
			if($key == $field_value) {
				$selected = 'selected';
			}
			$menu_output .= "\t<option {$selected} value=\"" . pl_html_escape($key) . "\">" . pl_html_escape_label($label) . "</option>\n";
		}
		$menu_output .= "</optgroup>\n";
	}
	
	
	$menu_output .= "</select>";
	
	return $menu_output;
}

?>