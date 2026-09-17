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

function pika_phone_orig(what)
{
	if (what.value.length == 3 && old_phone_length == 2)
	{
		what.value += '-';
	}

	old_phone_length = what.value.length;
}

function pika_phone(what)
{
	var valid_chars = "1234567890";
	var x;
	var i;
	
	for (i = 0; i < what.value.length; i++)
	{		
      if (valid_chars.indexOf(what.value.charAt(i)) < 0) 
      {
         what.value = what.value.substring(0, i) + what.value.substring(i+1);
      }
    }
    
    if (what.value.length > 3)
    {
    	what.value = what.value.substring(0, 3) + '-' + what.value.substring(3);
    }
}

//-->

document.addEventListener('DOMContentLoaded', function ()
{
	var area = document.querySelectorAll('.js-intake-area-code');
	for (var i = 0; i < area.length; i++)
	{
		area[i].addEventListener('keyup', function ()
		{
			pika_area_code(this, Number(this.getAttribute('data-area-max')), this.getAttribute('data-phone-field'));
		});
	}
	var phone = document.querySelectorAll('.js-intake-phone');
	for (var j = 0; j < phone.length; j++)
	{
		phone[j].addEventListener('keyup', function ()
		{
			pika_phone(this);
		});
	}
	document.form1.first_name.focus();
});
