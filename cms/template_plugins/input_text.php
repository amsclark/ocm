<?php
function input_text($field_name = null, $field_value = null, $menu_array = null, $args = null) {
	
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
		'size' => '',
		'maxlength' => '',
		'style' => '',
		// JS Directives
		'onchange' => '',
		'onfocus' => '', 
		'onblur' => '', 
		'onclick' => '',
		'onmouseup' => '',
		'onmousedown' => '',
		'onkeyup' => '',
		// Data Directives
		'default' => ''
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	// Begin building text
	
	// Every attribute below is escaped. Nothing here was, and this plugin
	// renders very nearly every single-line field in the application, so a
	// value carrying a double quote closed value="..." and grafted its own
	// attributes onto the <input>. Confirmed live: a filter value of
	// zz" onmouseover="alert(1) reached the browser as a working handler.
	//
	// Two helpers, for two kinds of input:
	//
	//   * value is content. Some of it is written as entities on purpose,
	//     because the %%[tag]%% parser splits on commas and quotes, so
	//     re-escaping it would show the user a literal "&amp;#44;".
	//     pl_html_escape_label() passes a fully-encoded string through and
	//     escapes anything else, and "anything else" includes every string
	//     that could break out of the attribute.
	//
	//   * name, id, class, style, size, maxlength, tabindex and the event
	//     handlers are structure, authored in templates and PHP and never
	//     entity-encoded. Those get pl_html_escape() outright.
	//
	// Escaping a handler attribute does not change what it does: the browser
	// decodes entities in an attribute value before the JS is parsed, so
	// onChange="f('x')" behaves the same either way. radio.php and menu.php
	// already did it this way.
	$text_output .= "<input type=\"text\" ";
	
	
	$text_output .= "name=\"" . pl_html_escape($field_name) . "\" ";
	$text_output .= "id=\"" . pl_html_escape($temp_args['id']) . "\" ";
	
	if(strlen($temp_args['default']) > 0 && (is_null($field_value) || strlen($field_value) < 1))
	{
		$field_value = $temp_args['default'];
	}	
	
	$text_output .= "value=\"" . pl_html_escape_label($field_value) . "\" ";
	if(isset($temp_args['class']) && strlen($temp_args['class']) > 0) {
		$text_output .= "class=\"" . pl_html_escape($temp_args['class']) . "\" ";
	}
	
	if(isset($temp_args['style']) && strlen($temp_args['style']) > 0) {
		$text_output .= "style=\"" . pl_html_escape($temp_args['style']) . "\" ";
	}
	
	if($temp_args['size'] != '') {
		$text_output .= "size=\"" . pl_html_escape($temp_args['size']) . "\" ";
	} if($temp_args['maxlength'] != '') {
		$text_output .= "maxlength=\"" . pl_html_escape($temp_args['maxlength']) . "\" ";
	}
	
	
	if($temp_args['onchange'] != '') { 
		$text_output .= "onChange=\"" . pl_html_escape($temp_args['onchange']) . "\" ";
	} if($temp_args['onclick'] != '') { 
		$text_output .= "onClick=\"" . pl_html_escape($temp_args['onclick']) . "\" ";
	} if($temp_args['onfocus'] != '') { 
		$text_output .= "onFocus=\"" . pl_html_escape($temp_args['onfocus']) . "\" ";
	} if($temp_args['onblur'] != '') { 
		$text_output .= "onBlur=\"" . pl_html_escape($temp_args['onblur']) . "\" ";
	} if($temp_args['onmouseup'] != '') { 
		$text_output .= "onMouseUp=\"" . pl_html_escape($temp_args['onmouseup']) . "\" ";
	} if($temp_args['onmousedown'] != '') { 
		$text_output .= "onMouseDown=\"" . pl_html_escape($temp_args['onmousedown']) . "\" ";
	}if($temp_args['onkeyup'] != '') { 
		$text_output .= "onKeyUp=\"" . pl_html_escape($temp_args['onkeyup']) . "\" ";
	}
	
	$text_output .= "tabindex=\"" . pl_html_escape($temp_args['tabindex']) . "\" ";
	
	if($temp_args['disabled']) {
		$text_output .= "disabled ";
	}
	
	$text_output .= "/>";
	
	return $text_output;

}




?>