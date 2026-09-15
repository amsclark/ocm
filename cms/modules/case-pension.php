<?php

$menu_mortality_table = array(
	'1' => "Combined Static",
	'2' => "Static",
	'3' => "Fully Generational",
	'4' => "417(e)",
	);

$menu_employee_sex = array(
	'F' => "Female",
	'M' => "Male",
	);
	
$menu_payment_form = array(
	'LS' => "Lump Sum"
	);

$case_row['valuation_year'] = date('Y');
$case_row['mortality_table'] = 4;
$case_row['payment_form'] = 'LS';
if($case_row['gender'] == 'M')
{
	$case_row['employee_sex'] = 'M';
}


if(is_numeric($case_row['client_age']))
{
	$case_row['employee_age'] = $case_row['client_age'];
}


$pension_template = new pikaTempLib('subtemplates/case-pension.html',$case_row);
$pension_template->addMenu('mortality_table',$menu_mortality_table);
$pension_template->addMenu('employee_sex',$menu_employee_sex);
$pension_template->addMenu('payment_form',$menu_payment_form);
$C .= $pension_template->draw();

?>
