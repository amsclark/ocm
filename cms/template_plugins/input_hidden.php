<?php


function input_hidden($field_name = null, $field_value = null, $menu_array = null, $args = null) {

	$hidden_output = '';

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
	'default' => ''
	);

	// Allow arg override
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);

	// Begin building hidden
	$hidden_output .= "<input type=\"hidden\" ";


	// Nothing here was escaped. Hidden fields carry ids and filter values
	// straight off the query string on several screens, so a value with a
	// double quote closed value="..." and added its own attributes to the
	// <input>. See input_text.php for why value uses the label helper.
	$hidden_output .= "name=\"" . pl_html_escape($temp_args['name']) . "\" ";
	$hidden_output .= "id=\"" . pl_html_escape($temp_args['id']) . "\" ";
	// If no value supplied substitute default value if specified
	// strlen() is cast because $field_value is null on every tag that supplies
	// no value, which is the common case -- one deprecation per hidden field.
	if(!$field_value && strlen((string) $field_value) < 1 && $temp_args['default']) {
		$field_value = $temp_args['default'];
	}
	$hidden_output .= "value=\"" . pl_html_escape_label($field_value) . "\" ";
	$hidden_output .= "/>";

	return $hidden_output;

}




?>