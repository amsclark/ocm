document.addEventListener('DOMContentLoaded', function ()
{
	var forms = document.querySelectorAll('.js-delete-agency');
	for (var i = 0; i < forms.length; i++)
	{
		forms[i].addEventListener('submit', function (e)
		{
			if (!confirm('Are you sure you want to Delete this Agency?'))
			{
				e.preventDefault();
			}
		});
	}
});
