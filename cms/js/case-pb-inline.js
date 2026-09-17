document.addEventListener('DOMContentLoaded', function ()
{
	var referralLinks = document.querySelectorAll('.js-case-pb-ref-date');
	for (var i = 0; i < referralLinks.length; i++)
	{
		referralLinks[i].addEventListener('click', function (e)
		{
			e.preventDefault();
			set_ref_date();
		});
	}

	var closeLinks = document.querySelectorAll('.js-case-pb-close-date');
	for (var j = 0; j < closeLinks.length; j++)
	{
		closeLinks[j].addEventListener('click', function (e)
		{
			e.preventDefault();
			set_close();
		});
	}
});
