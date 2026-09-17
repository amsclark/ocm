document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-index-toggle-motd');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function (e)
		{
			e.preventDefault();
			toggleMotd(this.getAttribute('data-motd-id'));
		});
	}
});
