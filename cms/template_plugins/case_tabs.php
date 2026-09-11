<?php

function case_tabs($field_name = null, $field_value = null, $menu_array = null, $args = null)
{
	
	if (!is_array($menu_array)){
		$menu_array = array();
	}if(!is_array($field_value)) {
		$field_value = array();
	}if(!is_array($args)) {
		$args = array();
	}
	
	$def_args = array(
		// JS Directives
		'onclick' => '', 
		'js_mode' => false,
		// Debug Directives
		'url' => '',
		'view' => 'enabled'
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	$base_url = pl_settings_get('base_url');
	$x = 0;
	$y = ''; // Standard case tabs.
	$yjs = ''; // JavaScript enabled case tabs.
	
	$case_tabs = array();
	
	$autosave = false;
	if(isset($menu_array["case-{$field_name}.php"]['autosave']) && $menu_array["case-{$field_name}.php"]['autosave'])
	{
		$autosave = true;
	}
	
	foreach ($menu_array as $key => $tab)
	{
		//print_r($tab);
		if(!$temp_args['view'] || ($tab['enabled'] && $temp_args['view'] == 'enabled') ||  (!$tab['enabled'] && $temp_args['view'] == 'disabled')) {
			$current = '';
			if ($tab['file'] == "case-{$field_name}.php"){
				$current = ' class="active"';
			}
			/*	The file column is nullable and the New Tab button writes a
				row without one, so a row saved without a module file reached
				substr(), strpos() and the sanitiser below as null -- two
				deprecation notices per tab per case page.
			*/
			$screen_name = (string) $tab['file'];
			if(substr($screen_name,0,5) == 'case-') {
				$screen_name = substr($screen_name,5);
			}
			$ext_location = strpos($screen_name,'.php');
			if($ext_location !== false) {
				$screen_name = substr($screen_name,0,$ext_location);
			}
			
			/*	The screen name is the module file name off the case_tabs
				row. It goes into the href below and, in JavaScript mode,
				into a single-quoted JavaScript string, so a row holding a
				quote in its file name put script of the writer's choosing
				on every case screen. A module file name is a plain word;
				keep the characters a file name can hold and drop the rest.
			*/
			$screen_name = preg_replace('/[^A-Za-z0-9_.-]/','',$screen_name);
			$onclick = '';
			if(strlen($temp_args['onclick']) > 0) {
				$onclick .= $temp_args['onclick'];
			}
			if($temp_args['js_mode'] && $autosave) {
				$onclick .= "if(typeof window.setConfirmUnload == 'function') setConfirmUnload(false); document.forms.ws.screen.value='{$screen_name}'; document.forms.ws.submit(); return false;";
			}
			/*	The tab name is typed in on the Case Tabs admin screen and
				went into the link as it came out of the table.
				pl_clean_html() rather than pl_html_escape(): the name was
				written through pl_grab_get(), which has already turned <
				and > into entities, so escaping a second time would show
				the user "&lt;" where the tab was named "<".
			*/
			$tab_name = pl_clean_html($tab['name']);
			$case_id = isset($field_value['case_id']) ? rawurlencode((string) $field_value['case_id']) : '';
			
			if(!isset($case_tabs[$tab['tab_row']])) { $case_tabs[$tab['tab_row']] = ''; }
			$case_tabs[$tab['tab_row']] .= "<li{$current}>";
			
			if($temp_args['url']) {
				$case_tabs[$tab['tab_row']] .= "<a href=\"{$temp_args['url']}screen={$screen_name}\" onClick=\"{$onclick}\">{$tab_name}</a>";
			} else {
				$case_tabs[$tab['tab_row']] .= "<a href=\"{$base_url}/case.php?case_id={$case_id}&screen={$screen_name}\" onClick=\"{$onclick}\">{$tab_name}</a>";				
			}
			$case_tabs[$tab['tab_row']] .= "</li>\n";
		}
	}
	ksort($case_tabs);
	$case_tabs_html = "<ul class=\"nav nav-tabs\">";
	$case_tabs_html .= implode("</ul>\n<ul class=\"nav nav-tabs\">",$case_tabs);
	$case_tabs_html .= "</ul>";
	
	
	return $case_tabs_html;
	
}