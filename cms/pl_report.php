<?php

$output_format = 'html';

function pl_report_headers($filename, $file_desc='')
{
	global $output_format;
	 
}

/*	pl_process_comma_vals() used to be defined again here, and the copy did
	not escape: it wrapped each value in double quotes and concatenated it,
	so a double quote in the input closed the string and the rest of the
	value became SQL. MariaDB accepts a double-quoted string literal unless
	ANSI_QUOTES is set, which this application does not set.
	
	It was unreachable. The definition in cms/app/lib/pl.php:5758, which
	escapes each value with DB::escapeString(), is not guarded by
	function_exists(), so it must always load first -- a second unguarded
	definition would be a fatal redeclare -- and the guard here therefore
	always skipped this one. Both files that include pl_report.php reach it
	after pl.php.
	
	Removed rather than repaired. It was one include-order change away from
	silently replacing an escaping function with a non-escaping one of the
	same name, and there is nothing a second copy can do that the first
	cannot.
*/

class pikaReport
{
	var $format = 'html';
	var $align = 'landscape';
	var $filename = 'pika-file';
	
	function setFormat($val)
	{
		if ('pdf' == $val || 'html' == $val || 'rtf' == $val)
			$this->format = $val;
		
		return $this->format;
	}

	function setAlign($val)
	{
		if ('landscape' == $val || 'portrait' == $val)
			$this->align = $val;
		
		return $this->align;
	}

	function display($buffer)
	{
		if ('html' == $this->format)
		{
			echo $buffer;
		}
	}
}

class pikaReportTable
{
    var $cols = array();  // array
    var $rows = array();  // 2D array

    var $col_bg = '#000088';
	var $col_fg = '#ffffff';
    var $rowa_bg = '#ffffff';
    var $rowb_bg = '#eeeeee';


    function plTable()
    {

    }
    
    function assignLabels($cols)
    {
	    $this->cols = $cols;
    }
    
    function addRow($rows)
    {
    	if (is_array($rows))
    	{
		    $this->rows[] = $rows;
    	}
    }
    
    function draw()
    {
    	$C = '';
    	
		// If there are no rows provided, create an empty array to avoid errors
		if (sizeof($this->rows) == 0)
		{
			$this->addRow(array(''));
		}

		// If $this->cols has not been specified, this will grab the db column names from the data in $rows
		if (sizeof($this->cols) == 0)
		{
			$this->cols = array_keys($this->rows[0]);
		}
	
	
		$col_count = count($this->cols);  // the number of columns
	
		$C .= "<table cellspacing=\"0\" cellpadding=\"0\">\n";
	
		// Column headers
		$C .= "<tr>\n";
	
		for ($i = 0; $i < $col_count; $i++)
		{
			$C .= '<th>';

			if ($this->cols[$i] == '')  // this column has no label
			{
				$C .= '&nbsp;';
			}

			else
			{
				// Draw the column label
				$C .= $this->cols[$i];
			}

			$C .= "</th>\n";
		}
	
		$C .= "</tr>\n";
		
		// main body of the table
	
		if (!is_array($this->rows))
		{
			/* no data to show, just draw one big empty row and let the use know 
			 * that there's no data
			 */
			$C .= "<tr class=\"$this->rowa_bg\">\n";
			$C .= '<td colspan=' . count($this->cols) . '><p>&nbsp;&nbsp;<i>nothing to display</i></p></td>' . "\n";
			$C .= '</tr>';
			$C .= "\n";
		}
	
		else
		{
			// data rows
			reset($this->rows);
			$z = 0;
			
			foreach (array_keys($this->rows) as $dummy)
			{
				if($z % 2 == 0)
					$C .= "<tr bgcolor='$this->rowa_bg' valign='top'>";
				else
					$C .= "<tr bgcolor='$this->rowb_bg' valign='top'>";
			
				$C .= "\n";
	
				reset($this->rows[$z]);
				
				foreach ($this->rows[$z] as $key => $val)
				{
					if ($val == '') // this test lets the value '0' through
						$C .= "<td><font size=-2>&nbsp;</font></td>\n";
	
					else 
						$C .= "<td><font size=-2>$val</font></td>\n";
				}
	
				$C .= "</tr>\n";
				$z++;
			}
		}
	
		$C .= '</table>';
		$C .= "\n";

		return $C;
	}
}


?>
