document.addEventListener('DOMContentLoaded', function ()
{
	var closeLinks = document.querySelectorAll('.js-case-info-close-date');
	for (var i = 0; i < closeLinks.length; i++)
	{
		closeLinks[i].addEventListener('click', function ()
		{
			set_close();
		});
	}
});
