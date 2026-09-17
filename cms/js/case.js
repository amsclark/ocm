document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-case-remove-client');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function (e)
		{
			var name = this.getAttribute('data-party-name');
			if (!confirm('Are you sure you want to remove ' + name + ' from this case?'))
			{
				e.preventDefault();
			}
		});
	}
});
