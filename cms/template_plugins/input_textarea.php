<?php
function input_textarea($field_name = null, $field_value = null, $menu_array = null, $args = null) {
	
	$text_output = '';
	
	if(is_array($field_value)) {
		$field_value = null;
	}
	
	if(!is_array($args)) {
		$args = array();
	}
	
	$def_args = array(
		// STD Directives
		'name' => $field_name,
		'id' => $field_name,
		'class' => '',
		'tabindex' => '1',
		'disabled' => false,
		'rows' => '3',
		'cols' => '33',
		// JS Directives
		'onfocus' => '', 
		'onblur' => '', 
		'onclick' => '',
		'onmouseup' => '',
		'onmousedown' => ''
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	// Begin building textarea
	
	
	$text_output .= "<textarea ";
	
	
	$text_output .= "name=\"" . pl_html_escape($field_name) . "\" ";
	$text_output .= "id=\"" . pl_html_escape($temp_args['id']) . "\" ";
	
	$text_output .= "class=\"" . pl_html_escape($temp_args['class']) . "\" ";
	
	if($temp_args['cols'] != '') {
		$text_output .= "cols=\"" . pl_html_escape($temp_args['cols']) . "\" ";
	} if($temp_args['rows'] != '') {
		$text_output .= "rows=\"" . pl_html_escape($temp_args['rows']) . "\" ";
	}
	
	
	if($temp_args['onclick'] != '') { 
		$text_output .= "onClick=\"" . pl_html_escape($temp_args['onclick']) . "\" ";
	} if($temp_args['onfocus'] != '') { 
		$text_output .= "onFocus=\"" . pl_html_escape($temp_args['onfocus']) . "\" ";
	} if($temp_args['onblur'] != '') { 
		$text_output .= "onBlur=\"" . pl_html_escape($temp_args['onblur']) . "\" ";
	} if($temp_args['onmouseup'] != '') { 
		$text_output .= "onMouseUp=\"" . pl_html_escape($temp_args['onmouseup']) . "\" ";
	} if($temp_args['onmousedown'] != '') { 
		$text_output .= "onMouseDown=\"" . pl_html_escape($temp_args['onmousedown']) . "\" ";
	}
	
	$text_output .= "tabindex=\"" . pl_html_escape($temp_args['tabindex']) . "\" ";
	
	if($temp_args['disabled']) {
		$text_output .= "disabled ";
	}
	
	$text_output .= "/>";
	// Escape on the way into the element. A <textarea> ends at the first
	// "</textarea", so a value carrying that string closes the field early and
	// everything after it parses as markup. Every notes field in the app comes
	// through here. Entities decode back to the typed characters inside a
	// textarea, so this is invisible for ordinary prose and only changes what
	// a value containing markup does, which is the bug.
	$text_output .= pl_html_escape($field_value);
	$text_output .= "</textarea>";
	
	
	return $text_output;

}