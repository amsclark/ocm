<?php

/**
* date_selector - draws calendar table 
*
* @var $field_name = Name of form field to populate with value
* @var $field_value = Current date stored in form field
* @var $container - The id of the DOMElement that will display the calendar (for js links)
* @param month = Display this month <default blank> - assumes current month if $field_value is blank
* @param year = Display this year <default blank> - assumes current year if $field_value is blank
* @author Matthew Friedlander <matt@pikasoftware.com>;
* @version 1.0
* @package Danio
*/
function date_selector($field_name = null, $field_value = null, $container = null, $args = null)
{
	
	if(strlen($field_value) < 1 || strtotime($field_value) === false) {
		$field_value = date('n/d/Y');
	}if(!is_array($args)) {
		$args = array();
	}
	
	$def_args = array(
		'month' => '',
		'year' => ''
	);
	
	// Allow arg override
	
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	$date_selector = '';
	
	// $field_name and $container are interpolated below into a single-quoted
	// JavaScript string that itself sits inside a double-quoted HTML attribute,
	// and they reach this plugin unfiltered from the unauthenticated
	// services/date_selector-server.php endpoint. That nesting needs TWO
	// escaping passes, not one: pl_html_escape() alone encodes an apostrophe as
	// &#039;, but the browser HTML-decodes an attribute value back to ' before
	// the JS parser ever sees it, so the string literal still breaks and the
	// attacker gets to append statements -- no angle bracket required, so an
	// entity filter watching only for < and > never sees it.
	//
	// So: json_encode() first, which returns a complete quoted JS literal with
	// every quote, backslash and control character escaped (the JSON_HEX_* flags
	// also encode ' " < > &, so nothing HTML-significant survives), then
	// pl_html_escape() the result for the attribute. Use the encoded copies
	// everywhere so no interpolation is missed or double-escaped. The literal
	// includes its own quotes, hence no '' around it at the call sites.
	$js_literal = function ($value)
	{
		return pl_html_escape(json_encode(
			(string)$value,
			JSON_HEX_APOS | JSON_HEX_QUOT | JSON_HEX_TAG | JSON_HEX_AMP
		));
	};
	
	$field_name_js = $js_literal($field_name);
	$container_js = $js_literal($container);
	
	$ts = strtotime($field_value);
	$month = date('n',$ts);
	$year = date('Y',$ts);
	
	
	
	// Determine display month/year
	$display_month = $temp_args['month'];
	if(!$display_month || !is_numeric($display_month)) {
		$display_month = $month;
	} 
	
	$display_year = $temp_args['year'];
	if(!$display_year || !is_numeric($display_year)) {
		$display_year = $year;
	}
	$first_day_of_month = $display_month."/1/".$display_year;
	$num_days_in_month = date('t',strtotime($first_day_of_month));
	$first_day_of_week = date('w',strtotime($first_day_of_month));
	$display_month_name = date('M',strtotime($first_day_of_month));
	
	
	// Draw calendar
	
	$date_selector .= "<table cellspacing=\"0\" cellpadding=\"2\"><tr class='DSCalHeader'>";
	// Generate previous month link
	$display_prev_month = $display_month;
	$display_prev_year = $display_year;
	if($display_month == 1) {
		$display_prev_month = 12;
		$display_prev_year = $display_year - 1;
	} else {
		$display_prev_month = $display_month - 1;
	}
	// Generate next month link
	$display_next_month = $display_month;
	$display_next_year = $display_year;
	if($display_month == 12) {
		$display_next_month = 1;
		$display_next_year = $display_year + 1;
	} else {
		$display_next_month = $display_month + 1;
	}
	// The month and year arguments are integers produced by date() arithmetic
	// above, never request data, so they are left interpolated as-is.
	$date_selector .= "<td><a onclick=\"date_selector(" . $field_name_js . "," . $container_js . ",'{$display_prev_month}','{$display_prev_year}');\">&lt;&lt;</a></td>";
	$date_selector .= "<td colspan='5' align='center'>". $display_month_name . " " . $display_year ."</td>";
	$date_selector .= "<td><a onclick=\"date_selector(" . $field_name_js . "," . $container_js . ",'{$display_next_month}','{$display_next_year}');\">&gt;&gt;</a></td>";
	$date_selector .= "</tr>";
	$date_selector .= "<tr class='DSCalDaysOfWeek'><td>Sun</td><td>Mon</td><td>Tue</td><td>Wed</td><td>Thu</td><td>Fri</td><td>Sat</td></tr>";
	
	$first_week = true;
	$current_week = $current_day = 1;
	while($current_day <= $num_days_in_month) {
		$date_selector .= "<tr class=\"DSCalWeek\">";
		for($day=0;$day<7;$day++) {
			// Determine if current day is equal to $field_value 
			$current_full_date = $display_month . "/" . $current_day . "/" . $display_year;
			$current_full_date_display = pikaTempLib::plugin('text_date','',$current_full_date);
			$selected_class = '';
			if($ts == strtotime($current_full_date) && $day == date('w',strtotime($current_full_date))) {
				$selected_class = 'DSCalSelectedDate';
			}
			$date_selector .= "<td class=\"" . pl_html_escape($selected_class) . "\">";
			if($first_week && $day == $first_day_of_week) {$first_week = false;} 
			if(!$first_week && $current_day <= $num_days_in_month) {
				$date_selector .= "<a onclick=\"selectDate(" . $field_name_js . ",'{$current_full_date_display}'," . $container_js . ");\">";
				$date_selector .= $current_day; 
				$date_selector .= "</a>";
				$current_day++;
			}
			$date_selector .= "</td>";
		}
		$date_selector .= "</tr>";
		$current_week++;
	}
	
	$date_selector .= "<tr class=\"DSCalFooter\"><td colspan=\"7\"><a onclick=\"closeCalendar(" . $container_js . ");\">Close [X]</a></td></tr></table>";
	
	return $date_selector;
	
}



