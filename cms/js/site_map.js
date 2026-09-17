document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-site-map-timer');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function (e)
		{
			popUp({url: this.href, name: this.getAttribute('data-window-name')});
			e.preventDefault();
		});
	}
});
