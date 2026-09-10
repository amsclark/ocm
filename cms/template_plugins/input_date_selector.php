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
	
	$date_selector_output = "<div class=\"input-group\">";
	$date_selector_output .= pikaTempLib::plugin('input_date',$field_name,$field_value,array(),$args);
	
	if(!isset($temp_args['disabled']) || !$temp_args['disabled']) 
	{
		// Same double-nesting as the date_selector plugin: a single-quoted JS
		// string inside a double-quoted HTML attribute, so encode for JS with
		// json_encode() (the JSON_HEX_* flags leave nothing HTML-significant)
		// and then HTML-escape for the attribute. field_name reaches this
		// plugin from custom-field template tags. $container_name is generated
		// here, but goes through the same path so the two cannot drift.
		$js_literal = function ($value)
		{
			return pl_html_escape(json_encode(
				(string)$value,
				JSON_HEX_APOS | JSON_HEX_QUOT | JSON_HEX_TAG | JSON_HEX_AMP
			));
		};
		
		$date_selector_output .= "<div class=\"input-group-append\"><button class=\"btn\" type=\"button\" onclick=\"openCalendar(" . $js_literal($field_name) . "," . $js_literal($container_name) . ");\">";
		$date_selector_output .= "<i class=\"far fa-calendar\"></i></button></div>";
	}
	
	else
	{
		$date_selector_output .= "<button class=\"btn\" type=\"button\"><i class=\"icon-lock\"></i></button>";
	}
	
	$date_selector_output .= "</div>";
	$date_selector_output .= "<div id=\"" . pl_html_escape($container_name) . "\" style=\"z-index:3;clear:both;position:absolute;background-color:white;display:none;border:solid;border-width:1px;\"></div>";
	
	return $date_selector_output;

}




?>