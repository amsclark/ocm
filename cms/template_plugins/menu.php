<?php


function menu($field_name = null, $field_value = null, $menu_array = null, $args = null)
{
	if (!is_array($menu_array))
	{
		$menu_array = array();
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
		'style' => '',
		'tabindex' => '1',
		'disabled' => false,
		// JS Directives
		'onfocus' => '', 
		'onblur' => '', 
		'onchange' => '',
		// Data Directives
		'noblank' => false,
		'nomsg' => false,
		'default' => '',
		'first_value' => false,
		// Format Directive
		'text' => false
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	if($temp_args['text'])
	{
		return pikaTempLib::plugin('text_menu',$field_name,$field_value,$menu_array,$args);
	}
	
	// Begin building menu
	$menu_output = '';
	$menu_output .= "<select ";
	
	$menu_output .= "name=\"" . pl_html_escape($temp_args['name']) . "\" ";
	$menu_output .= "id=\"" . pl_html_escape($temp_args['id']) . "\" ";
	$menu_output .= "class=\"" . pl_html_escape($temp_args['class']) . "\" ";
	$menu_output .= "style=\"" . pl_html_escape($temp_args['style']) . "\" ";
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
	
	if(strlen($temp_args['default']) > 0 && (is_null($field_value) || strlen($field_value) < 1))
	{
		$field_value = $temp_args['default'];
	}
	elseif($temp_args['first_value'] && count($menu_array) > 0 && (is_null($field_value) || strlen($field_value) < 1))
	{
		$menu_keys = array_keys($menu_array);
		$field_value = $menu_keys[0];
	}
	
	
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
	if (count($menu_array) < 1 && !$temp_args['nomsg'])
	{
		$menu_output .= "<option value=\"\">No Menu Available</option>\n";
	}
	
	foreach ($menu_array as $key => $label) {
		$selected = '';
		
		if(!is_null($field_value) && strlen($field_value) > 0 && (strcmp((string)$key,(string)$field_value) == 0)) {
			$selected = 'selected';
		}
		
		// The option VALUE is escaped; the LABEL deliberately is not. Menu
		// labels come from the per-org menu_* tables and some ship pre-encoded
		// entities (menu_comparison_sql.label holds &gt; and &lt; for the SQL
		// comparison operators), so escaping here would double-encode them and
		// show users the raw entity text. Labels are admin-curated reference
		// data, not request input. Escaping them properly means first cleaning
		// the stored data, which is a data migration, not a code change.
		$menu_output .= "<option {$selected} value=\"" . pl_html_escape($key) . "\">{$label}</option>\n";
	}
	
	
	$menu_output .= "</select>";
	
	return $menu_output;
}

?>