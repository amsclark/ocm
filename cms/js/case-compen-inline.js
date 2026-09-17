document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-case-compen-confirm');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function ()
		{
			confirm(this.getAttribute('data-confirm'));
		});
	}
});
