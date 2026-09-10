<?php

function multiselect($field_name = null, $field_value = null, $menu_array = null, $args = null)
{
	
	if (!is_array($menu_array))
	{
		$menu_array = array();
	}
	
	if(!is_array($args)) {
		$args = array();
	}
	
	$def_args = array(
		// STD Directives
		'name' => $field_name,
		'id' => $field_name,
		'class' => 'plmenu',
		'style' => '',
		'size' => '',
		'tabindex' => '1',
		'disabled' => false,
		// JS Directives
		'onfocus' => '', 
		'onblur' => '', 
		'onchange' => '',
		'noblank' => false,
		'nomsg' => false
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	// Begin building menu
	$menu_output = '';
	//$menu_output .= "<input type=\"hidden\" name=\"{$temp_args['name']}\" value=\"\" />";
	$menu_output .= "<select multiple ";
	
	$menu_output .= "name=\"" . pl_html_escape($temp_args['name']) . "[]\" ";
	$menu_output .= "id=\"" . pl_html_escape($temp_args['id']) . "\" ";
	$menu_output .= "class=\"" . pl_html_escape($temp_args['class']) . "\" ";
	$menu_output .= "style=\"" . pl_html_escape($temp_args['style']) . "\" ";
	if($temp_args['size'] != '') {
		$menu_output .= "size=\"" . pl_html_escape($temp_args['size']) . "\" ";
	}
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
	// Handle Blanks
	if($temp_args['noblank']) {
		if(!is_array($field_value) && (is_null($field_value) || strlen($field_value) < 1)) {  // Enter blank if and only if value is blank
			$menu_output .= "<option selected value=\"\">&nbsp;</option>\n";
		}
	} else { // Blanks are shown - Check if field is blank to mark as selected
		$selected = '';
		if(is_null($field_value) || strlen($field_value) < 1) {
			$selected = 'selected';
		}
		$menu_output .= "<option {$selected} value=\"\">&nbsp;</option>\n";
	}
	// Handle values not in menu
	//
	// This branch fires exactly when the stored value is not one of the
	// curated menu keys, which is to say when nobody vetted it. It reached
	// both the attribute and the visible text raw.
	if (is_array($field_value)) {
		foreach ($field_value as $val) {
			if(!isset($menu_array[$val]) && strlen($val) > 0) {
				$menu_output .= "<option selected value=\"" . pl_html_escape($val) . "\">" . pl_html_escape($val) . "</option>\n";
			}
		}
	}
	elseif (!is_null($field_value) && !isset($menu_array[$field_value]) && strlen($field_value) > 0) {
		$menu_output .= "<option selected value=\"" . pl_html_escape($field_value) . "\">" . pl_html_escape($field_value) . "</option>\n";
	}
	
	// catch any cases where no menu data is available
	if (count($menu_array) < 1 && !$temp_args['nomsg'])
	{
		$menu_output .= "<option value=\"\">No Menu Available</option>\n";
	}
	// Handle all matching values
	foreach ($menu_array as $key => $label) {
		$selected = '';
		if(is_array($field_value)) {
			if(in_array($key,$field_value)){
				$selected = 'selected';
			}
		}
		elseif($key == $field_value) {
			$selected = 'selected';
		}
		// The key is an attribute value, so a bare double quote in it closes
		// value=" without needing an angle bracket. The label is content, and
		// some labels are stored already entity-encoded because the %%[tag]%%
		// parser splits on commas and quotes, so it goes through the label
		// helper instead. Menu rows are editable in the app and arrive from
		// per-org overlays, so neither is authored here.
		$menu_output .= "<option {$selected} value=\"" . pl_html_escape($key) . "\">" . pl_html_escape_label($label) . "</option>\n";
	}
	
	
	$menu_output .= "</select>";
	
	return $menu_output;
}

?>
