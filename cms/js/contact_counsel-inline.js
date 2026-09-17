/*	A KeyPress(what, max, action) helper stood here. Its whole body passed
	the action argument to eval, so it ran whatever string a caller handed
	it. Nothing in the tree ever called it, so it is deleted rather than
	rewritten.
*/

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


function pika_phone(what)
{
	if (what.value.length == 3 && old_phone_length == 2)
	{
		what.value += '-';
	}

	old_phone_length = what.value.length;
}

document.fc.first_name.focus();

(function ()
{
	var area = document.querySelectorAll('.js-contact-counsel-area-code');
	for (var i = 0; i < area.length; i++)
	{
		area[i].addEventListener('keyup', function ()
		{
			pika_area_code(this, Number(this.getAttribute('data-area-max')), this.getAttribute('data-phone-field'));
		});
	}

	var phone = document.querySelectorAll('.js-contact-counsel-phone');
	for (var j = 0; j < phone.length; j++)
	{
		phone[j].addEventListener('keyup', function ()
		{
			pika_phone(this);
		});
	}
}());
