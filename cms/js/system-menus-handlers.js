document.addEventListener('DOMContentLoaded', function ()
{
	var forms = document.querySelectorAll('.js-menu-item');
	for (var i = 0; i < forms.length; i++)
	{
		forms[i].addEventListener('submit', function (e)
		{
			validate();
			e.preventDefault();
		});
	}
});
