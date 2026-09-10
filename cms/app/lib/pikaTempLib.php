<?php

/************************************/
/* Pika Software (C) 2010    		*/
/* written by Matthew Friedlander  	*/
/* http://www.pikasoftware.com		*/
/************************************/


/**
* pikaTempLib - Pika Template Engine 
*
* Class that examines files or strings for template tags and replaces them with
* php variables to build screens and for forms assembly
* 
* @author Matthew Friedlander <matt@pikasoftware.com>;
* @version 1.00
* @package Danio
*/

require_once('pikaMenu.php');

class pikaTempLib {
	
	public $_template_prefix = '%%[';
	public $_template_suffix = ']%%';
	public $_legacy_templates = true;
	
	private $_file_name;
	private $_data;
	private $_menus = array();
	private $_args = array();
	private $_template_string;
	private $_subtemplate_name;
	
	
	/**
	 * __construct() - Creates instance of pikaTempLib
	 *
	 * @param string $template_file - Either a string or the relative location of a template file
	 * under either the main Pika CMS directory or the custom folders 
	 * @param array $data_array - The array of php variables to be referenced and substituted for template tags
	 * @param string $subtemplate_name - The name of the subtemplate within the referenced $template_file that
	 * is selected
	 */
	public function __construct($template_file, $data_array = null, $subtemplate_name = null)
	{
		// Take care of input variables - die if necessary
		if(!is_null($template_file) && $template_file) 
		{
			if(!is_array($data_array)) 
			{
				$this->_data = array();
			}
			else 
			{ 
				$this->_data = $data_array; 
			}
		} 
		else 
		{
			trigger_error('Filename or string is blank: ' . substr($template_file,0,50)); 
		}

		// Insure filename is an existing file in either custom or main templates
		// First, use the custom template path search algorithm if one is installed.
		if (file_exists(pl_custom_directory() . "/extensions/template_path/template_path.php"))
		{
			require_once(pl_custom_directory() . "/extensions/template_path/template_path.php");
			$template_file = template_path($template_file);
		}

		else if (file_exists(pl_custom_directory() . "/{$template_file}"))
		{
			$template_file = pl_custom_directory() . "/{$template_file}";
		}

		if(!file_exists($template_file)) 
		{ 
			// String mode - For document assembly primarily
			$this->_template_string = $template_file;
		} 
		else 
		{
			// File mode
			$this->_file_name = $template_file;
			$this->_template_string = file_get_contents($template_file);
		} 
		// Set the subtemplate if provided
		$this->_subtemplate_name = $subtemplate_name;
		// Catch PHP USER notices/warnings/errors
		$this->loadWarnings();
		// Load System Settings
		if(!$this->loadSettings()) 
		{
			trigger_error('System settings were not found');
		}
	}
	
	/**
	 * subTemplate - This function removes subtemplates from parsed file/string.
	 * 
	 * @param string $subtemplate_name - If null - whole template will be searched and subtemplates removed
	 * and replaced with a single tag of same name (e.g. %%[begin:a]%%-%%[end:a]%% results %%[a]%% for inline templates).
	 * If not null - function will search for that subtemplate and return it as the $template_string
	 * @return string $template_string - The modified $template_string depending on which mode
	 * 
	 */
	private function subTemplate() 
	{
		$template_string = '';
		if (is_null($this->_template_string) || !$this->_template_string) 
		{ 
			//$template_string = 'subTemplate: Supplied template file/string is null or empty!';
			return false;
		} 
		else 
		{ 
			$template_string = $this->_template_string; 
		}
		
		$prefix_position = $suffix_position = false;
		if (is_null($this->_subtemplate_name) || !$this->_subtemplate_name) 
		{	
			$prefix_position = strpos($template_string,$this->_template_prefix . 'begin:');
			$prefix_offset = strlen($this->_template_prefix . 'begin:');
			// Remove all subtemplates from file
			while ($prefix_position !== false) 
			{
				$suffix_position = strpos($template_string,$this->_template_suffix,$prefix_position);
				if($suffix_position !== false) { // We have located a complete tag!
					$sub_name_length = $suffix_position - ($prefix_position+$prefix_offset);
					$subtemplate_name = substr($template_string,$prefix_position + $prefix_offset, $sub_name_length);
					// Search for corresponding close tag
					$sub_end_tag = $this->_template_prefix . 'end:' . $subtemplate_name . $this->_template_suffix;
					$sub_end_tag_position = strpos($template_string,$sub_end_tag,$prefix_position);
					if ($sub_end_tag_position !== false) 
					{ 
						// End tag discovered
						$sub_end_tag_length = strlen($sub_end_tag);
						$sub_length = ($sub_end_tag_position + $sub_end_tag_length) - $prefix_position;
						$sub_string = substr($template_string,$prefix_position,$sub_length);
						// Create tag for subtemplate - for inline subtemplates
						$template_string = str_replace($sub_string,$this->_template_prefix . $subtemplate_name . $this->_template_suffix,$template_string);
						$prefix_position = strpos($template_string,$this->_template_prefix . 'begin:',$prefix_position);
					}
					else 
					{ 
						// No end tag discovered - truncate string at prefix position
						$template_string = substr($template_string,0,$prefix_position);
						$prefix_position = false;  // End the loop
					}
				}
			}
		}
		else 
		{
			// if subtemplate name is submitted return only that subtemplate
			$sub_begin_position = strpos($template_string,$this->_template_prefix . 'begin:' . $this->_subtemplate_name . $this->_template_suffix);
			$sub_begin_offset = strlen($this->_template_prefix . 'begin:' . $this->_subtemplate_name . $this->_template_suffix);

			if ($sub_begin_position !== false) 
			{
				// Locate end tag for subtemplate
				$sub_end_position = strpos($template_string,$this->_template_prefix . 'end:' . $this->_subtemplate_name . $this->_template_suffix,$sub_begin_position);
				//$sub_end_offset = strlen($this->_template_prefix . 'end:' . $this->subtemplate_name . $this->_template_suffix);
				if($sub_end_position !== false) 
				{ 
					// We have located a complete subtemplate
					$subtemplate_length = $sub_end_position - ($sub_begin_position + $sub_begin_offset);
					$subtemplate_string = substr($template_string,$sub_begin_position+$sub_begin_offset,$subtemplate_length);
					$template_string = trim($subtemplate_string);
				}
				else
				{ 
					// begin tag w/ no end tag return all string following open tag
					$subtemplate_string = substr($template_string,$sub_begin_position + $sub_begin_offset);
					$template_string = trim($subtemplate_string);
				}
				 
			}
			else 
			{
				$template_string = "subTemplate: {$this->_subtemplate_name} not found in supplied template.";
			}
		}
		
		return $template_string;
	}
	
	
	/**
	 * legacyTemplate - This function removes subtemplates from parsed file/string.
	 * 
	 * @param string $template_string - 
	 * @param string $template_prefix - A set of characters designating the start of a template tag (default '%%[')
	 * @param string $template_suffix - A set of characters designating the end of a template tag (default ']%%')
	 * @return string $template_string - The modified template string with legacy tags converted to pikaTempLib formatted tags
	 * 
	 */
	public static function legacyTemplate($template_string,$template_prefix = '%%[',$template_suffix = ']%%') {
		$legacy_temp_matches = array();
		while(preg_match('/%%\[[a-z_-]*\s(menu|vradio|radio|checkbox|text)(\s.*\]%%|\]%%)/',$template_string,$legacy_temp_matches)) 
		{			
			$current_tag = $legacy_temp_matches[0];
			$updated_tag = self::plugin('legacy_tag_converter','',$current_tag,'',array("template_prefix={$template_prefix}","template_suffix={$template_suffix}"));
			$template_string = str_replace($current_tag,$updated_tag,$template_string);	
		}
		return $template_string;
	}
	
	/**
	 * draw - Searches $_template_string for template tags and replaces them with referenced values
	 * from $_data depending on the directive in the template tag.  There are 3 methods that this function
	 * can choose between: direct replacement, menu lookup, custom plugin - depending on the template tag.
	 * 
	 * %%[var_name]%% - direct replacement
	 * %%[var_name,menu_name]%% - menu lookup (eg. dropdown menu typically)
	 * %%[var_name,plugin_name]%% - calls custom function from template_plugins to complete the replacement
	 *
	 * @return string $template_string - The string with all template tags removed and replaced with $_data values
	 */
	public function draw() 
	{
		// Pre-fill the CSRF token so the bare %%[csrf_field]%% tag in form
		// templates resolves through the plain-variable lookup path. Without
		// this the tag finds nothing there, renders as an empty string, and
		// every CSRF-gated POST returns 403 for every real user. A caller
		// that set csrf_field itself keeps its own value, so this is purely
		// additive.
		if(function_exists('pl_csrf_hidden_input')
			&& (!isset($this->_data['csrf_field']) || $this->_data['csrf_field'] === ''))
		{
			$this->_data['csrf_field'] = pl_csrf_hidden_input();
		}
		
		// Check subTemplates
		$this->_template_string = $this->subTemplate();
		// Check for legacy templates
		if($this->_legacy_templates) 
		{
			$this->_template_string = $this->legacyTemplate($this->_template_string,$this->_template_prefix,$this->_template_suffix);
		}
		// Locates all tags within string and returns completed string
		$temp_str = $this->_template_string;
		$suffix_position = false;
		
		// Reductive process
		$prefix_offset = strlen($this->_template_prefix);
		$prefix_position = strpos($temp_str,$this->_template_prefix);
		while ($prefix_position !== false) 
		{
			$tag_output_offset = 0; // To prevent template recursion into replaced strings
									// ex: template tag replaced with string that contains
									// more template tags - TODO: give option to turn on & off at runtime
				$suffix_position = strpos($temp_str,$this->_template_suffix,$prefix_position);
				if($suffix_position !== false) 
				{ 
					// We have located a complete tag!
					$tag_length = $suffix_position - ($prefix_position + $prefix_offset);
					$tag = substr($temp_str,$prefix_position+$prefix_offset,$tag_length);
					
				
					
					// Directives mode
					
					if(strpos($tag,',') !== false) 
					{ 	
						// Check for commas w/in quotes 
						//(ex. javascript function call: "funct1(opt1,opt2)"
						if(strpos($tag,'"') !== false)
						{
							$tag_array = $this->parseTagQuotes($tag);
						}
						else { // No quotes proceed normally
							$tag_array = explode(',',$tag);	
						}
						// Options mode
						// Need to split out directives and N-number arguments
						// %%[fieldname, directive, arg1, arg2, ... ]%%
						$tag_output = '';
						if(isset($tag_array[1]) && $tag_array[1]) 
						{ 
							// Verify directive specified 
							$field_name = $tag_array[0];
							$directive = $tag_array[1];
							
							$args = array_slice($tag_array,2);
							// 3 steps - check _menus, check /template_plugin dirs,
							// and finally determine if it is a database menu_* type
							$field_value = '';
							if(isset($this->_data[$field_name])) 
							{
								$field_value = $this->_data[$field_name];
							}
							else 
							{
								$field_value = $this->_data;
							}
							
							
							if ($this->loadMenu($directive)) 
							{  
								// If custom menu load it up
								// If the output type is specified (eg. radio, checkbox, etc)
								// load up custom function and get output
								// otherwise assume default 'menu' type
								if(isset($args[0]) && $args[0] && $this->loadModule($args[0])) 
								{ // Check if output type specified
									$tag_output = $args[0]($field_name,$field_value,$this->_menus[$directive],array_merge($args,$this->_args),$this->_data);
								} 
								else 
								{ // no recognized output type specified assume default menu dropdown
									if($this->loadModule('menu')) 
									{
										$tag_output = menu($field_name,$field_value,$this->_menus[$directive],array_merge($args,$this->_args));
									}
								}
							}
							elseif ($this->loadModule($directive)) 
							{
								// Case 2 - directive does not refer to menu but custom type
								// ex. textinput
								$tag_output = $directive($field_name,$field_value,array(),array_merge($args,$this->_args),$this->_data);
							}
							
							
						}
						$temp_str = str_replace($this->_template_prefix . $tag . $this->_template_suffix, $tag_output, $temp_str);
						$tag_output_offset = strlen($tag_output);
					
					}
					else 
					{ 
						// Direct replacement mode
						// lookup values in $data array
						$matched_value = '';
						if(isset($this->_data[$tag])) 
						{
							$matched_value = $this->_data[$tag];
						} 
						$temp_str = str_replace($this->_template_prefix . $tag . $this->_template_suffix, $matched_value, $temp_str);
						$tag_output_offset = strlen($matched_value);
					
					}
				} 
				else 
				{ 
					// opening tag with no closing tag
					$temp_str = substr($temp_str,0,$prefix_position);
					$temp_str .= "\n<!--missing closing tag - string truncated -->";
				}
			
			$prefix_position = strpos($temp_str,$this->_template_prefix,$prefix_position+$tag_output_offset);
		}
		
		return $temp_str;
	}
	
	
	/**
	 * loadModule - locates a template_plugin from either the custom or main pika directories
	 * and loads it.
	 *
	 * @param string $op_name - the name of the file under template_plugins (also the name of the function in that file)
	 * @return boolean - true if the function is successfully loaded
	 *                 - false on failure
	 */
	private static function loadModule ($op_name = null) 
	{
		// Locates requested module base on tag operators
		if (is_null($op_name) || !$op_name) 
		{ 
			return false;
		} 
		
		/*	$op_name is interpolated into a filesystem path just below and
			then called as a function name, so it should always be a plain
			identifier. Nothing enforced that. Every caller in this tree
			passes either a literal or a directive read out of a template
			file on disk, and the tag loop in parse() resumes its scan past
			the text it just substituted, so request data placed into a tag
			value is not re-parsed as a tag -- there is no known request path
			that reaches here. The check is here so that stays true: a value
			containing ../ would make require_once() reach outside
			template_plugins/ and execute whatever it found. Constrain it to
			what a PHP function name can actually be; every real plugin
			already matches.
		*/
		if (!preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', (string) $op_name))
		{
			return false;
		}
		
		if (file_exists(pl_custom_directory() . "/template_plugins/{$op_name}.php")) 
		{
			require_once(pl_custom_directory() . "/template_plugins/{$op_name}.php");
		} 
		elseif (file_exists(getcwd() . "/template_plugins/{$op_name}.php")) 
		{
			require_once(getcwd() . "/template_plugins/{$op_name}.php");
		} 
		else 
		{
			return false;
		}
		
		// Ensures that function by same name is defined
		if(function_exists($op_name)) 
		{ 
			return true;
		} 
		else 
		{ 
			return false; 
		}
		
	}
	
	/**
	 * addMenu - Allows custom generated menus to be included 
	 * for reference during template replacement
	 *
	 * @param string $menu_name - The name of the menu to be referenced in template tags
	 * @param unknown_type $menu_array - The data array of the menu (in key->label format)
	 */
	public function addMenu ($menu_name = null, $menu_array = null) 
	{
		if (!is_null($menu_name) && $menu_name && is_array($menu_array)) 
		{
			$this->_menus[$menu_name] = $menu_array;
		}
	}
	
	/**
	 * loadMenu - Check to see if menu is already loaded or 
	 * if it exists in DB load it into object in $_menus array
	 *
	 * @param string $menu_name - name of DB menu
	 * @return boolean - true if the menu is already loaded or is successfully loaded
	 *                 - false on failure
	 */
	private function loadMenu ($menu_name = null) 
	{
		$is_loaded = false;
		if(!is_null($menu_name) && strlen($menu_name) > 0) 
		{
			if(isset($this->_menus[$menu_name])) 
			{
				$is_loaded = true;
			} 
			elseif (is_array($tmp_menu = pikaTempLib::getMenu($menu_name))) 
			{
				$this->_menus[$menu_name] = $tmp_menu;
				$is_loaded = true;
			}
		}
		return $is_loaded;
	}
	
	/**
	 * getMenu - Retrieve a menu from the DB and load it into an array
	 * This function first checks to see if a menu by the name $menu_name exists
	 * and if so loads it.
	 *
	 * @param string $menu_name - The name of the menu (can be with or w/o 'menu_' prefix)
	 * @return array|false - if successful an array key->label format false on failure
	 */
	public static function getMenu($menu_name = null) 
	{
		$tmp_menu = false;
		if(pikaMenu::menuExists($menu_name)) 
		{
			$tmp_menu = pikaMenu::getMenu($menu_name);
		}
		return $tmp_menu;
	}
	
	/**
	 * addTemplateArg - Allows user to specify global arguments that
	 * are applied to each template tag if applicable (e.g. disabled - to disable all inputs)
	 *
	 * @param string $arg - in the format arg_name=arg_value or arg_name
	 */
	public function addTemplateArg($arg = null) 
	{
		if(!is_null($arg) && strlen($arg) > 3) 
		{
			$this->_args[] = $arg;
		}
	}
	
	/**
	 * loadSettings - Accesses the settings.php configuration file and loads
	 * environment variables such as base_url and adds them to the $_data array
	 *
	 * @return true
	 */
	public function loadSettings () 
	{
		require_once('pikaSettings.php');
		$plSettings = pikaSettings::getInstance();
		
		$blocked_fields = array('db_user','db_password');
		
		foreach ($plSettings as $setting => $value)
		{	
			if(!in_array($setting,$blocked_fields) && !isset($this->_data[$setting]))
			{
				$this->_data[$setting] = $plSettings[$setting];
			}
		}
		return true;
	}
	
	/**
	 * public function parseTagQuotes
	 * 
	 * Escapes tag commas inside of double quotes ("")
	 * 
	 * @param string $tag - The template tag to parse
	 * @return array $tag_array - The tag parsed as an array
	 */
	public function parseTagQuotes ($tag = null) 
	{
		
		$return_tag = array();
		if(strlen($tag) > 0)
		{
			$tag_array = explode(',',$tag);			
			$return_tag = array();
			$j = 0;
			$begin_found = false;
			
			for ($i=0;$i<count($tag_array);$i++)
			{
				if(strpos($tag_array[$i],'"') !== false)
				{
					if(!$begin_found)
					{ // Opening tag
						$begin_found = true;
						$return_tag[$j] = str_replace('"','',$tag_array[$i]);
					}
					else
					{ // Closing tag
						$begin_found = false;
						$return_tag[$j] .= ',' . str_replace('"','',$tag_array[$i]);
						$j++;
					}
				}
				else
				{ // no "s
					if(!$begin_found)
					{ // Not inside of tag proceed normally
						$return_tag[$j] = $tag_array[$i];
						$j++;
					}
					else
					{ // Inside of tag append to last index
						$return_tag[$j] .= ','.$tag_array[$i];	
					}
				}
			}
		}
		return $return_tag;
	}	
	
	/**
	 * loadWarnings - displays any E_USER_NOTICE|WARNING|ERROR 
	 * events and displays them at the bottom of the template (typically default.html).
	 * In prior versions of Pika these were not captured and would display as text at
	 * the top of each page upsetting the page formatting.
	 *
	 */
	public function loadWarnings () 
	{
		$this->_data['php_warnings'] = $this->plugin('pika_warning');
	}
	
	/**
	 * public static function plugin - loads and runs template_plugins
	 *
	 * @param string $op_name - name of file and function under template_plugins
	 * @param string $field_name - the name of the field this plugin renders
	 * @param string|array $field_value - the value of the input field or text
	 * @param array $menu_array - array of menu values (can also be a string depending on the plugin called)
	 * @param array $args - array of args in the format arg_name=arg_value or arg_name
	 * @return The output of the template plugin or false on failure
	 */
	public static function plugin($op_name, $field_name = null, $field_value = null, $menu_array = null, $args = null, $data = null) 
	{
		if(pikaTempLib::loadModule($op_name)) 
		{
			return $op_name($field_name, $field_value, $menu_array, $args, $data);
		}
		return false;
	}
	
	
	/**
	 * getPluginArgs - merges the default arguments from a template plugin with the
	 * arguments supplied at runtime and returns an array
	 *
	 * @param array $default_args - The default arguments of a plugin in an 
	 * array in the format arg_name=arg_value or arg_name
	 * @param array $runtime_args - The arguments supplied to a plugin in an
	 *  array in the format arg_name=arg_value or arg_name
	 * @return array - The merged array on success
	 *         false - On failure
	 */
	public static function getPluginArgs($default_args = null,$runtime_args = null) 
	{
		if(is_array($default_args)) 
		{
			if(!is_array($runtime_args) || count($runtime_args) == 0) 
			{
				return $default_args;
			}
			else 
			{ 
				// Generate Complete Argument Array
				foreach ($runtime_args as $val) 
				{
					if(strpos($val,'=') !== false) 
					{ 	
						// Arg assignment found
						$val_array = explode('=',$val,2);
						if(!isset($default_args[$val_array[0]])) 
						{ 
							// Check if arg is recognized type
							$default_args[$val_array[0]] = '';
						} 
						if(isset($val_array[1])) 
						{  
							// Override with new value
							$default_args[$val_array[0]] = $val_array[1];
						}
					} 
					else 
					{ 
						// Single keyword assignment (ex. disabled)
						if(!isset($default_args[$val])) 
						{ 
							$default_args[$val] = true;
						} 
						else 
						{
							if($default_args[$val] === true) {$default_args[$val] = false;} // If true set false
							else {$default_args[$val] = true;} // If anything else set true
						}	
					}
				}
				return $default_args;
			}
		}
		else 
		{
			return false;
		}
	}
	
	
	/**
	 * setPluginArgs - sets an array of arguments into the 
	 * format of an array of arg_name=arg_value or arg_name.  This allows
	 * chaining of template plugins (e.g. input_date uses input_text to render 
	 * and needs to pass arguments forward)
	 *
	 * @param array $temp_args
	 * @return array $args
	 */
	public static function setPluginArgs($temp_args = null) 
	{
		$args = array();
		if(is_array($temp_args)) 
		{
			foreach ($temp_args as $key => $val) 
			{
				if (!strlen($val) && is_bool($val)) 
				{ 
					// single keyword argument
					if($val) 
					{
						$args[] = $key;
					}
				} 
				else 
				{
					$args[] = "{$key}={$val}";
				}
			}
			return $args;
		} 
		else 
		{
			return false;
		}
	}
}

?>
