(function ()
{
	var area = document.querySelectorAll('.js-contact-full-area-code');
	for (var i = 0; i < area.length; i++)
	{
		area[i].addEventListener('keyup', function ()
		{
			pika_area_code(this, Number(this.getAttribute('data-area-max')), this.getAttribute('data-phone-field'));
		});
	}

	var phone = document.querySelectorAll('.js-contact-full-phone');
	for (var j = 0; j < phone.length; j++)
	{
		phone[j].addEventListener('keyup', function ()
		{
			pika_phone(this);
		});
	}

	var zip = document.querySelectorAll('.js-contact-full-zip');
	for (var k = 0; k < zip.length; k++)
	{
		zip[k].addEventListener('blur', function ()
		{
			zipcode_lookup(this.value);
		});
	}
}());
