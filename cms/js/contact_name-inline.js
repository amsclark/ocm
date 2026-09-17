var old_ssn_length = 0;

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

document.con_name.first_name.focus();
