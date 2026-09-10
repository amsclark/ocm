<?php


function ul($field_name = null, $field_value = null, $menu_array = null, $args = null)
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
		'ul_class' => '',
		'li_class' => '',
		'key_class' => false
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	/*
	What is and is not escaped below.
	
	Every attribute this plugin emits is escaped, because an attribute value
	is where a stray double quote closes the attribute and starts a new one.
	The id on the <li> in the scalar branch is the one with a live source:
	pikaMisc::reportList() keys its array by report directory name, so $key
	is a filesystem name this app does not control.
	
	The <li> body is deliberately NOT escaped, in either branch. This plugin
	is a raw-HTML list builder, not a label renderer, and every caller passes
	markup it built itself: reportList(), reports/index.php, file_list.php
	and the menu columns in subtemplates/system-menus.html all hand it
	anchors. Escaping the body would turn all four into visible angle
	brackets. Callers stay responsible for escaping the user data they put
	into the body, which is what reportList() and file_list.php already do.
	*/
	
	// Begin building unordered list
	$ul_output = '<ul';
	if($field_name) {
		$ul_output .= ' id="' . pl_html_escape($field_name) . '"';
	}
	if($temp_args['ul_class']) {
		$ul_output .= ' class="' . pl_html_escape($temp_args['ul_class']) . '"';
	}
	$ul_output .= ">\n";
	
	
	foreach ($menu_array as $key => $label) {
		if(is_array($label))
		{
			$ul_output .= "\t<li";
			if(isset($label['id']) && $label['id']) 
			{
				$ul_output .= ' id="' . pl_html_escape($label['id']) . '"';
			}
			if(isset($label['li_class']) && $label['li_class']) 
			{
				$ul_output .= ' class="' . pl_html_escape($label['li_class']) . '"';
			}
			$ul_output .= ">";
			if(isset($label['li'])) 
			{
				$ul_output .= $label['li'];
			}
			$ul_output .= "</li>\n";
		}
		else {
			$ul_output .= "\t<li";
			if($field_value) {
				$ul_output .= ' id="' . pl_html_escape($field_value . '-' . $key) . '"';
			}
			if($temp_args['li_class']) 
			{
				$ul_output .= ' class="' . pl_html_escape($temp_args['li_class']) . '"';
			}
			$ul_output .= ">{$label}</li>\n";
		}
	}
	
	
	$ul_output .= "</ul>\n";
	
	return $ul_output;
}

?>