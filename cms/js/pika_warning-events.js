document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-pika-warning-toggle');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function (e)
		{
			e.preventDefault();
			toggleWarnings();
		});
	}
});
