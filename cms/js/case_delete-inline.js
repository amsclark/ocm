document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-case-delete-confirm');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function (e)
		{
			if (!confirm(this.getAttribute('data-confirm')))
			{
				e.preventDefault();
			}
		});
	}
});
