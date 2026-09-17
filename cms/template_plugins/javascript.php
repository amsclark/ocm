<?php
function javascript($file_name = null, $field_value = null, $menu_array = null, $args = null) {

	$javascript_output = '';
	
	// Ensure that the htmlTempLib data array was passed
	// Only needed if parse argument is set
	if (!is_array($field_value)) {
		$field_value = array();
	}
	
	if(!is_array($args)) {
		$args = array();
	}
	
	$def_args = array(
		// STD Directives
		'parse' => false,
		'script_tags' => true
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	// Begin building javascript
	
	// Locates requested javascript based on name of file
	if (is_null($file_name) || !$file_name) { // if no file_name specified return blank
		return $javascript_output;
	} 
	/*	The name came out of the template tag and went straight into
		pl_custom_directory() . "/js/{$file_name}" and
		getcwd() . "/js/{$file_name}", with nothing checking its shape and
		nothing rejecting ../ -- so a tag could walk out of the js directory
		and file_get_contents() anything the web server could read, and with
		parse on, render it through the template engine. Every js file this
		application ships is a bare name in one flat directory, which is the
		shape pl_safe_js_file_name() requires.
	*/
	if (!pl_safe_js_file_name($file_name)) {
		return htmlspecialchars((string) $file_name) . " not found";
	}
	
	// Allow js file overload
	// Check to see if custom js file has been created
	$js_file_string = '';
	if(file_exists(pl_custom_directory() . "/js/{$file_name}")) {
		$js_file_string = file_get_contents(pl_custom_directory() . "/js/{$file_name}");
	} elseif (file_exists(getcwd() . "/js/{$file_name}")) {
		$js_file_string = file_get_contents(getcwd() . "/js/{$file_name}");
	}
	
	else 
	{
		$js_file_string = htmlspecialchars($file_name) . " not found";
	}
	
	// If the js file needs to be templated (usually for base_url) then run another template object
	if ($temp_args['parse'] === true) {
		$javascript_template = new pikaTempLib($js_file_string,$field_value);
		$javascript_output = $javascript_template->draw();
	} else {
		$javascript_output = $js_file_string;
	}
	
	
	// Add opening and closing declarations
	$js_open = $js_close = '';
	if($temp_args['script_tags']) {
		/*	This is the one place left in the tree that writes an inline script
			block. The 68 files included as %%[<name>.js,javascript]%% are inlined
			rather than fetched because several of them hold template tags, and a
			tag is only substituted on the way through here.

			The nonce is what lets script-src drop 'unsafe-inline'. Without it the
			policy would have to permit every inline script on the page, including
			one an attacker injected; with it the browser runs this block and
			nothing else. The value is escaped like any other attribute even
			though it is base64 from random_bytes, because an unescaped attribute
			is a habit worth not having.
		*/
		$js_nonce = '';
		if (function_exists('pl_csp_nonce'))
		{
			$js_nonce = ' nonce="' . htmlspecialchars(pl_csp_nonce(), ENT_QUOTES) . '"';
		}
		
		$js_open = "<script{$js_nonce} language=\"JavaScript\" type=\"text/javascript\"><!-- \n";
		$js_close = "   \n//--></script>";
	}
	$javascript_output = $js_open . $javascript_output . $js_close;
	
	return $javascript_output;



}
?>