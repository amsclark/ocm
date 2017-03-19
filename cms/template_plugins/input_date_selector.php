<?php
function input_date_selector($field_name = null, $field_value = null, $menu_array = null, $args = null) {
	
	$text_output = '';
	
	if(is_array($field_value)) {
		$field_value = null;
	}
	
	if(!is_array($args)) {
		$args = array();
	}
	
	$def_args = array(
		// STD Directives
		'class' => 'date_selector',
		'style' => '',
		'maxlength' => '10',
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	$args = pikaTempLib::setPluginArgs($temp_args);
	
	$base_url = pl_settings_get('base_url');
	
	$container_name = "date_selector-".str_pad(rand(0,99999),5,'0');
	
	$date_selector_output = "<div class=\"input-append\">";
	$date_selector_output .= pikaTempLib::plugin('input_date',$field_name,$field_value,array(),$args);
	
	if(!isset($temp_args['disabled']) || !$temp_args['disabled']) 
	{
		$date_selector_output .= "<button class=\"date-range-icon\" type=\"button\" onclick=\"openCalendar('{$field_name}','{$container_name}');\">";		
		$date_selector_output .= "<i class=\"material-icons\">date_range</i></button>";
	}
	
	else
	{
		$date_selector_output .= "<button class=\"btn\" type=\"button\"><i class=\"icon-lock\"></i></button>";
	}
	
	$date_selector_output .= "</div>";
	$date_selector_output .= "<div id=\"{$container_name}\" style=\"z-index:3;clear:both;position:absolute;background-color:white;display:none;border:solid;border-width:1px;\"></div>";
	
	return $date_selector_output;

}




?>
