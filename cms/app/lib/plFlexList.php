<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('pl.php');

/**
* Creates HTML tables based on a template file.
*
* @author Aaron Worley <amworley@pikasoftware.com>;
* @version 1.0
* @package Danio
*/
class plFlexList
{
    /**
    * The path of the template file.
    * @arg string
    */
    public $template_file;
	public $template_array = array(); // private
	public $rows_buffer;
	public $column_names = array();  // private
	public $flex_header_name = 'flex_header';  // private
	public $flex_row_name = 'flex_row';  // private
	public $flex_footer_name = 'flex_footer';  //private
	public $table_url = '';
	public $get_url = '';
	public $order_field = '';
	public $order = '';
	public $total_records = 0;
	public $records_per_page = 0;
	public $page_offset = 0;
	public $pager_prefix = '';  // Optional; use this if you have multiple flex pagers on one screen.
	public $stripe_counter = 1;
	
	
	public function __construct()
	{
		
		return true;
	}

	
	/**
	* Determine what filters are being used on the table.
	*
	* Extend description.
	*
	* @return boolean
	* @param array $filter
	*/
	public function setFilterParams($filter)
	{
		// Determine the GET section of the table screen URL.
		foreach ($filter as $key => $val)
		{
			$this->get_url .= pl_clean_html($key) . '=' . pl_clean_html($val) . '&';
		}
		
		return true;
	}
	
	
	/**
	* @return string
	* @param 
	* @desc something.
	*/
	public function getRowCss()
	{
		if (1 == $this->stripe_counter) 
		{
			$this->stripe_counter = 2;
			return 'row1';
		}
		
		else 
		{
			$this->stripe_counter = 1;
			return 'row2';
		}
	}

	/**
	* @return boolean
	* @param array $row
	* @desc Adds a new row to the bottom of the table being built.
	*/
	public function addRow($row)
	{
		if (!isset($row['css_class'])) 
		{
			$row['css_class'] = $this->getRowCss();
		}
		
		$clean_row = pl_clean_html_array($row);
		$this->rows_buffer .= pl_template($this->template_file, $clean_row, $this->flex_row_name);
		
		return true;
	}
	
	
	public function addFancyTextRow($row)
	{
		if (!isset($row['css_class'])) 
		{
			$row['css_class'] = $this->getRowCss();
		}
		
		$clean_row = pl_html_text_array($row);
		$this->rows_buffer .= pl_template($this->template_file, $clean_row, $this->flex_row_name);
		
		return true;
	}
	
	
	public function addHtmlRow($row)
	{
		if (!isset($row['css_class'])) 
		{
			$row['css_class'] = $this->getRowCss();
		}
		
		$this->rows_buffer .= pl_template($this->template_file, $row, $this->flex_row_name);
		return true;
	}
	
	
	public function generatePager()
	{
		// The pager.
		$pager_str = '';
		$pager_url = "{$this->table_url}?{$this->get_url}{$this->pager_prefix}order_field={$this->order_field}&{$this->pager_prefix}order={$this->order}";		
		$current_page = $last_page = 0;
		if($this->records_per_page > 0)
		{
			$current_page = (int) ($this->page_offset / $this->records_per_page);
			$last_page = (int) (($this->total_records - 1) / $this->records_per_page);
		}
		
		$pager_str .= "<table class=\"pager-table\"><tr>\n<td>";
		
		if ($current_page > 0)
		{
			$t = ($current_page - 1) * $this->records_per_page;
			$pager_str .= "<a href=\"{$pager_url}&{$this->pager_prefix}offset={$t}\">Previous {$this->records_per_page}</a>";
		}
		
		$pager_str .= "</td>\n<td>";
		
		if ($last_page < 10)
		{
			// don't have to worry about shortening the pager
			
			for ($x = 0; $x <= $last_page; $x++)
			{
				$y = $x + 1;
				
				if ($x == $current_page)
				{
					$pager_str .= '<strong> ' . $y . ' </strong>&nbsp;';
				}
				
				else
				{
					$w = $x * $this->records_per_page;
					$pager_str .= "<a href=\"{$pager_url}&{$this->pager_prefix}offset={$w}\"> {$y} </a>&nbsp;";
				}
			}
		}
		
		// this code keeps the size of the pager at or under 10 pages, if needed
		
		// show (up to) the first 10 pages
		else if ($current_page < 8)
		{
			for ($x = 0; $x < 10; $x++)
			{
				$y = $x + 1;
				
				if ($x == $current_page)
				{
					$pager_str .= '<strong> ' . $y . ' </strong>&nbsp;';
				}
				
				else
				{
					$w = $x * $this->records_per_page;
					$pager_str .= "<a href=\"{$pager_url}&{$this->pager_prefix}offset={$w}\"> {$y} </a>&nbsp;";
				}
			}
			
			$w = $last_page * $this->records_per_page;
			$y = $last_page + 1;
			$pager_str .= " ... <a href=\"{$pager_url}&{$this->pager_prefix}offset={$w}\"> {$y} </a>&nbsp;";
		}
		
		// show the last 10 pages
		else if ($current_page > ($last_page - 11))
		{
			$pager_str .= "<a href=\"{$pager_url}&{$this->pager_prefix}offset=0\"> 1 </a> ... ";
			
			for ($x = $last_page - 9; $x <= $last_page; $x++)
			{
				$y = $x + 1;
				
				if ($x == $current_page)
				{
					$pager_str .= '<strong> ' . $y . ' </strong>&nbsp;';
				}
				
				else
				{
					$w = $x * $this->records_per_page;
					$pager_str .= "<a href=\"{$pager_url}&{$this->pager_prefix}offset={$w}\"> {$y} </a>&nbsp;";
				}
			}
		}
		
		else // stuck in the middle...
		{
			$pager_str .= "<a href=\"{$pager_url}&{$this->pager_prefix}offset=0\"> 1 </a> ... ";
			
			for ($x = $current_page; $x < $current_page + 10; $x++)
			{
				$y = $x + 1;
				
				if ($x == $current_page)
				{
					$pager_str .= '<strong> ' . $y . ' </strong>&nbsp;';
				}
				
				else
				{
					$w = $x * $this->records_per_page;
					$pager_str .= "<a href=\"{$pager_url}&{$this->pager_prefix}offset={$w}\"> {$y} </a>&nbsp;";
				}
			}
			
			$w = $last_page * $this->records_per_page;
			$y = $last_page + 1;
			$pager_str .= " ... <a href=\"{$pager_url}&{$this->pager_prefix}offset={$w}\"> {$y} </a>&nbsp;";
		}
				
		$pager_str .= "</td>\n<td align=right width=100>";
		
		if ($current_page < $last_page)
		{
			$t = ($current_page + 1) * $this->records_per_page;
			$pager_str .= "<a href=\"{$pager_url}&{$this->pager_prefix}offset={$t}\">Next {$this->records_per_page}</a>";
		}
		
		$pager_str .= "</td>\n</tr></table>\n";
		
		return $pager_str;
	}
	
	public function draw()
	{
		$base_url = pl_settings_get('base_url');
		$pager_html = '';
		
		if ('ASC' != $this->order)
		{
			$this->order = 'DESC';
		}
				
		foreach ($this->column_names as $val)
		{
			$next_order = 'ASC';
			
			if ($val == $this->order_field && 'ASC' == $this->order)
			{
				$next_order = 'DESC';
			}
			
			$this->template_array["{$val}_url"] = "{$this->table_url}?{$this->get_url}order_field={$val}&order={$next_order}";
			
			if ($val == $this->order_field)
			{
				if ('ASC' == $this->order)
				{
					// $this->template_array["{$val}_img"] = "<img src=\"{$base_url}/images/asc.gif\" alt=\"Asc.\"/>";
				}
				
				else
				{
					// $this->template_array["{$val}_img"] = "<img src=\"{$base_url}/images/desc.gif\" alt=\"Desc.\"/>";
				}
			}
			
			else
			{
				$this->template_array["{$val}_img"] = '';
			}
		}
		
		if ($this->records_per_page < $this->total_records)
		{
			$pager_html = $this->generatePager();
		}
		
		/* If no rows were added (and rows_buffer is zero-length), don't display the table,
		it'll look weird with just a header and a footer and no rows.  Otherwise,
		display the table normally.
		*/
		if (strlen($this->rows_buffer) < 1)
		{
			return "<p><em>No records found.</em></p>";
		}
		
		else 
		{
			return pl_template($this->template_file, $this->template_array, $this->flex_header_name)
			. $this->rows_buffer
			. pl_template($this->template_file, $this->template_array, $this->flex_footer_name)
			. $pager_html;
		}
	}
	
	public function setTemplatePrefix($prefix)
	{
		$clean_prefix = pl_clean_html($prefix);
		$this->flex_header_name = "{$clean_prefix}header";
		$this->flex_row_name = "{$clean_prefix}row";
		$this->flex_footer_name = "{$clean_prefix}footer";
		return true;
	}
}

?>
