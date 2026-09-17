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

var ac_autotab_on = 1;

function pika_area_code(what, max, field_name)
{
	if (max > 0 && what.value.length >= max && ac_autotab_on == 1)
	{
		document.form1[field_name].focus();
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

var old_phone_length = 0;

function pika_phone(what)
{
	if (what.value.length == 3 && old_phone_length == 2)
	{
		what.value += '-';
	}

	old_phone_length = what.value.length;
}

document.form1.first_name.focus();

(function ()
{
	var area = document.querySelectorAll('.js-case-contact-list-area-code');
	for (var i = 0; i < area.length; i++)
	{
		area[i].addEventListener('keyup', function ()
		{
			pika_area_code(this, Number(this.getAttribute('data-area-max')), this.getAttribute('data-phone-field'));
		});
	}

	var phone = document.querySelectorAll('.js-case-contact-list-phone');
	for (var j = 0; j < phone.length; j++)
	{
		phone[j].addEventListener('keyup', function ()
		{
			pika_phone(this);
		});
	}

	var contacts = document.querySelectorAll('.js-case-contact-list-popup');
	for (var k = 0; k < contacts.length; k++)
	{
		contacts[k].addEventListener('click', function (e)
		{
			e.preventDefault();
			popUp({url: this.href, name: this.getAttribute('data-popup-name')});
		});
	}
}());
