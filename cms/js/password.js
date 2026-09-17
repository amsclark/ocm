document.addEventListener('DOMContentLoaded', function ()
{
	var suggest = document.querySelectorAll('.js-suggest-password');
	for (var i = 0; i < suggest.length; i++)
	{
		suggest[i].addEventListener('click', function ()
		{
			make_password();
		});
	}
	var use = document.querySelectorAll('.js-use-password');
	for (var j = 0; j < use.length; j++)
	{
		use[j].addEventListener('click', function ()
		{
			use_password(this.getAttribute('data-password-first'));
			use_password(this.getAttribute('data-password-second'));
			updateStrengthDisplay(document.suggest.newpass.value);
		});
	}
	var strength = document.querySelectorAll('.js-password-strength');
	for (var k = 0; k < strength.length; k++)
	{
		strength[k].addEventListener('keyup', function ()
		{
			updateStrengthDisplay(this.value);
		});
	}
});
