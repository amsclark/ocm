<?php

function calendar_tabs($field_name = null, $field_value = null, $menu_array = null, $args = null)
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
		// Debug Directives
		'url' => '',
		'view' => 'enabled'
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	$base_url = pl_settings_get('base_url');
	
	
	
	$calendar_tabs = array();
	$menu_array = array(
		array('file' => 'cal_day.php', 'name' => 'Day View', 'screen' => '', 'tab_row' => '1', 'enabled' => '1'),
		array('file' => 'cal_week.php', 'name' => 'One Week', 'screen' => 'one', 'tab_row' => '1', 'enabled' => '1'),
		array('file' => 'cal_week.php', 'name' => 'Four Week', 'screen' => 'four', 'tab_row' => '1', 'enabled' => '1'),
		array('file' => 'cal_adv.php', 'name' => 'Advanced', 'screen' => '','tab_row' => '1', 'enabled' => '1')
	);
	
	
	foreach ($menu_array as $key => $tab)
	{
		
		//print_r($tab);
		if(!$temp_args['view'] || ($tab['enabled'] && $temp_args['view'] == 'enabled') ||  (!$tab['enabled'] && $temp_args['view'] == 'disabled')) {
			$current = '';
			if ($tab['file'] == "cal_{$field_name}.php"){
				$current = ' class="active"';
			}
			
			if(!isset($calendar_tabs[$tab['tab_row']])) { $calendar_tabs[$tab['tab_row']] = ''; }
			$calendar_tabs[$tab['tab_row']] .= "<li{$current}>";
			
			if(!isset($field_value['user_id'])) { $field_value['user_id'] = ''; }
			if(!isset($field_value['cal_date'])) { $field_value['cal_date'] = date('Y-m-d'); }
			
			if($temp_args['url']) {
				$calendar_tabs[$tab['tab_row']] .= "<a href=\"{$temp_args['url']}screen={$tab['screen']}\">{$tab['name']}</a>";
			} else {
				$calendar_tabs[$tab['tab_row']] .= "<a href=\"{$base_url}/{$tab['file']}?screen={$tab['screen']}&cal_date={$field_value['cal_date']}&user_id={$field_value['user_id']}\">{$tab['name']}</a>";
			}
			$calendar_tabs[$tab['tab_row']] .= "</li>\n";
		}
	}
	ksort($calendar_tabs);
	$calendar_tabs_html = "<ul class=\"nav nav-tabs\">";
	$calendar_tabs_html .= implode("</ul>\n<ul>",$calendar_tabs);
	$calendar_tabs_html .= "</ul>";
	
	
	return $calendar_tabs_html;
	
}
