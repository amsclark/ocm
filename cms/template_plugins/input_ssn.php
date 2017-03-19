<?php
function input_ssn($field_name = null, $field_value = null, $menu_array = null, $args = null) 
{
	$C = '';
	$ssn_type = null;
	$result = mysql_query("DESCRIBE contacts") or trigger_error(mysql_error());
	
	while ($row = mysql_fetch_assoc($result))
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
		$C .= "<label for=\"ssn\">SSN</label> \n";
		$C .= '<input type="text" name="ssn" onkeyup="pika_ssn(this);" value="' . htmlentities($field_value) . '" maxlength="11" tabindex="1">';
	}

	$C .= "<br/>\n";
	
	return $C;
}




?>
