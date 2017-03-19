<?php


function lsc_close_code($field_name = null, $field_value = null, $menu_array = null, $args = null)
{
	
	if(!is_array($field_value)){
		$field_value = array();
	}
	
	// MDF - Assume 2008 defaults
	$menu_output = "<label for=\"special-problem-code\">LSC Problem Code (2008 codes)</label>\n";
	$menu_name = 'close_code_2008';
	
	// AMW - Begin of LSC 2008 CSR section.
	$year_opened = $current_year = date('Y');
	if(isset($field_value['open_date']) && strlen($field_value['open_date']) > 0) 
	{
		$year_opened = date('Y',strtotime($field_value['open_date']));
	}
	$year_closed = '';
	if(isset($field_value['close_date']) && strlen($field_value['close_date']) > 0) 
	{
		$year_closed = date('Y',strtotime($field_value['close_date']));
	}
	
	/*
	The following if clause chooses whether to use the 2007 or the 2008 closing and 	
	problem codes based on the case's open and closed dates.
	
	Cases that are closed in 2007 or earlier will use the 2007 codes.  Cases that are
	closed in 2008 or later will use the 2008 codes.
	Cases that haven't been closed are more complicated.  If they were opened in 2008 or
	later, they will use 2008 codes.
	*/
	
	if(
		(is_numeric($year_opened) && $year_opened < 2008 && is_numeric($year_closed) && $year_closed < 2008)
		||
		(is_numeric($current_year) &&  $current_year < 2008)
		)
	{
		$menu_output = "LSC Closing Code (2007 codes):<br />\n";
		$menu_name = 'close_code_2007';
		
	}
	

	$menu_array = pikaTempLib::getMenu($menu_name);

	// AMW - End of LSC 2008 CSR.
	$close_code = '';
	if(isset($field_value['close_code'])) {
		$close_code = $field_value['close_code'];
	}
	
	$menu_output .= pikaTempLib::plugin('menu','close_code',$close_code,$menu_array,$args);
	
	return $menu_output;
}

?>
