<?php
function radio($field_name = null, $field_value = null, $menu_array = null, $args = null) {

	$radio_output = '';
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
		'class' => 'plradio',
		'tabindex' => '1',
		'disabled' => false,
		// JS Directives
		'onfocus' => '', 
		'onblur' => '',
		'onclick' => '',
		// Display Directives
		'vertical' => false
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	// Begin building radio
	
	foreach ($menu_array as $key => $label) {
		$checked = '';
		if($key == $field_value) {
			$checked = 'checked';
		}
		
		$number_pad = str_pad(rand(0,99999),5,'0');
		$uid = "{$temp_args['id']}_" . $number_pad;
		
		
		// $key comes off the menu_* tables and reaches both an attribute value
		// and the label text. Escape it once here and reuse, alongside the $uid
		// the input's id carries.
		$key_attr = pl_html_escape($key);
		$uid_attr = pl_html_escape($uid);
		
		$radio_output .= "<label><input type=\"radio\" ";
		$radio_output .= "name=\"" . pl_html_escape($temp_args['name']) . "\" ";
		$radio_output .= "id=\"{$uid_attr}\" ";
		$radio_output .= "value=\"{$key_attr}\"";
		$radio_output .= "class=\"" . pl_html_escape($temp_args['class']) . "\" ";
		$radio_output .= "tabindex=\"" . pl_html_escape($temp_args['tabindex']) . "\" ";
		
		if($temp_args['onfocus'] != '') { 
			$radio_output .= "onFocus=\"" . pl_html_escape($temp_args['onfocus']) . "\" ";
		}if($temp_args['onblur'] != '') { 
			$radio_output .= "onBlur=\"" . pl_html_escape($temp_args['onblur']) . "\" ";
		}if($temp_args['onclick'] != '') { 
			$radio_output .= "onClick=\"" . pl_html_escape($temp_args['onclick']) . "\" ";
		}
		
		if ($temp_args['disabled']) {
			$radio_output .= "disabled ";
		}
		$radio_output .= "{$checked} />" . pl_html_escape($label) . "</label> ";
		if ($temp_args['vertical']) {
			$radio_output .= "<br/>\n";
		} else { $radio_output .= "&nbsp; "; }
		
	}
	
	return $radio_output;



}
?>