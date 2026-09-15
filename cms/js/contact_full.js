document.fc.first_name.focus();

var old_ssn_length = 0;
var old_phone_length = 0;
var ac_autotab_on = 1;


function pika_area_code(what, max, field_name)
{	
	if (max > 0 && what.value.length >= max && ac_autotab_on == 1)
	{
		document.fc[field_name].focus();
	}
	
	if (what.value.length >= 3)
	{
		ac_autotab_on = 0;
	}
	
	else if (what.value.length == 0)
	{
		ac_autotab_on = 1;
	}
	
	return;
}


function pika_ssn(what)
{
	if (what.value.length == 3 && old_ssn_length == 2)
	{
		what.value += '-';
	}
	
	if (what.value.length == 6 && old_ssn_length == 5)
	{
		what.value += '-';
	}

	old_ssn_length = what.value.length;
}


function pika_phone(what)
{
	if (what.value.length == 3 && old_phone_length == 2)
	{
		what.value += '-';
	}

	old_phone_length = what.value.length;
}
