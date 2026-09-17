document.addEventListener('DOMContentLoaded', function ()
{
	var zip = document.querySelectorAll('.js-user-zip');
	for (var i = 0; i < zip.length; i++)
	{
		zip[i].addEventListener('blur', function ()
		{
			zipcode_lookup(this.value);
		});
	}
	var suggest = document.querySelectorAll('.js-user-suggest-password');
	for (var j = 0; j < suggest.length; j++)
	{
		suggest[j].addEventListener('click', function ()
		{
			make_password();
		});
	}
	var use = document.querySelectorAll('.js-user-use-password');
	for (var k = 0; k < use.length; k++)
	{
		use[k].addEventListener('click', function ()
		{
			use_password(this.getAttribute('data-password-field'));
		});
	}
});
