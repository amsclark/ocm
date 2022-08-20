<?php

$output_format = 'html';

// determine the format the report will be displayed in
if ($output_format != 'html' && $output_format != 'pdf' && $output_format != 'rtf')
{
	$output_format = 'pdf';
}


function pl_report_headers($filename, $file_desc='')
{
	global $output_format;
	 
}

/*
Convert a string of comma separated values into SQL code that can be
used with the IN operator
*/
if(!function_exists('pl_process_comma_vals')) {
function pl_process_comma_vals($str)
{
	$a = explode(",", $str);
	
	$i = 0;
	
	$out = "(";
	
	foreach ($a as $val)
	{
		if ("" != $val)
		{
			if ($i > 0)
			{
				$out .= ",";
			}
			
			$out .= "\"$val\"";
			
			$i++;
		}
	}
	
	$out .= ")";
	
	if ($i > 0)
	{
		return $out;
	}
	
	else 
	{
		return false;
	}
}
}

class pikaReport
{
	var $format = 'pdf';
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
		global $plSettings;
		
		$rand_str = substr(md5(microtime()), 0, 5);
		// doesn't seem to help
		// header('Cache-control: private');
		
		// PDF will crash netscape 4.x on win32 test system
		// But this is taking out IE 6 as well.
		/*
		if (strstr($_SERVER['HTTP_USER_AGENT'], 'Mozilla/4.'))
		{
			$this->format = 'html';
		}
		*/

		if ('pdf' == $this->format)
		{
			$fp = fopen(PL_TMP_PATH . "/csr-$rand_str.html", 'w');
			fputs($fp, $buffer);
			fclose($fp);

			$pdf_command = "htmldoc -t pdf \
									--{$this->align} --no-links \
									--webpage --gray --textfont courier --headingfont courier\
									--header \"   \" --footer \"   \" \
									--fontsize 10 --top 0.5in --bottom 0.5in \
									--left 0.5in --right 0.5in " . PL_TMP_PATH . "/csr-$rand_str.html";

			
			// Dropbox method.
			/*
			$pdf_buffer = shell_exec("$pdf_command");

			$fp = fopen("dropbox/{$this->filename}-$rand_str.pdf", 'w');
			fputs($fp, $pdf_buffer);
			fclose($fp);
			
			header("Location: {$plSettings['base_url']}/dropbox/{$this->filename}-$rand_str.pdf");
			*/
			
			
			// Passthru-echo method.
			$pdf_buffer = shell_exec($pdf_command);
			
			header("Pragma: cache");
			header('Content-Type: application/pdf');
			
			// AMW - 2004-01-02
			//header("Accept-Ranges: bytes"); 

			header('Content-Disposition: inline; filename="file.pdf"');
			
			// AMW - 2004-02-17
			//flush();

			echo $pdf_buffer;
			
			
			/*
			// Passthru-flush method.
			header("Content-Type: application/pdf");
			header('Content-Disposition: inline; filename="file.pdf"');
		    flush();
		    passthru($pdf_command);
			*/
			
			//passthru($pdf_command);

			/*
			if (strstr($HTTP_USER_AGENT, 'MSIE'))
			{
				$attachment = ' inline';
			}

			else
			{
				$attachment = ' attachment;';
			}
			*/
			// header( "Content-Disposition:$attachment filename={$this->filename}.{$this->output_format}" );
			// header( "Content-Description: $file_desc" );
				
			/*
			NOTE: In Internet Explorer, the Content-Disposition header is important, otherwise it will be 
			inline. 'Content-Disposition: attachment' will ALWAYS make IE download it.

			NOTE: In Netscape, if you want to force it to be a download (i.e. not inline), use 
			header('Content-Type: application/octet-stream').
			*/
			//$buffer = str_replace("'", "\'", $buffer);

			unlink(PL_TMP_PATH . "/csr-$rand_str.html");
			exit();
		}

		else if ('rtf' == $this->format)
		{
			$fp = fopen("dropbox/{$this->filename}-$rand_str.rtf", 'w');
			fputs($fp, $buffer);
			fclose($fp);
			
			header("Location: {$plSettings['base_url']}/dropbox/{$this->filename}-$rand_str.rtf");
			exit();
		}

		else if ('html' == $this->format)
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
