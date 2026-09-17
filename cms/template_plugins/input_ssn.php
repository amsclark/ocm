<?php
function input_ssn($field_name = null, $field_value = null, $menu_array = null, $args = null) 
{
	static $ssn_script_included = false;

	if (is_array($field_value)) {
                   $field_value = $field_value[0];
    }
	$C = '';
	$ssn_type = null;
	if (is_array($field_value))
	{
		$field_value = null;
	}
	$result = DB::query("DESCRIBE contacts") or trigger_error(DB::error());
	
	while ($row = DBResult::fetchRow($result))
	{
		if ($row['Field'] == 'ssn')
		{
			$ssn_type = $row['Type'];
		}
	}
	
	if ($ssn_type == 'char(0)')
	{
		return '';
	}
	
	else if ($ssn_type == 'varchar(4)' || $ssn_type == 'char(4)')
	{
		$C .= "Last Four Digits of SSN:<br/>\n";	
		$C .= '<div class="input-prepend"><div class="add-on">???-??-</div>';
		$C .= '<input type="text" name="ssn" class="span2" value="' . htmlentities($field_value) . '" maxlength="4" tabindex="1">';
		$C .= "</div>";		
	}
	
	else
	{
		$base_url = pl_settings_get('base_url');
		$C .= "SSN:<br/>\n";
		$C .= '<input type="text" name="ssn" class="js-ssn-mask" value="' . htmlentities($field_value) . '" maxlength="11" size="22" tabindex="1">';
		if (!$ssn_script_included)
		{
			$C .= '<script src="' . $base_url . '/js/ssn-mask.js"></script>';
			$ssn_script_included = true;
		}
	}

	$C .= "<br/>\n";
	
	return $C;
}




?>
