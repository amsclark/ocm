document.addEventListener('DOMContentLoaded', function ()
{
	var boxes = document.querySelectorAll('.js-text-format');
	for (var i = 0; i < boxes.length; i++)
	{
		boxes[i].addEventListener('click', function (e)
		{
			var link = e.target.closest('a');
			if (!link || !this.contains(link))
			{
				return;
			}
			e.preventDefault();
			if (link.hasAttribute('data-tag'))
			{
				AddTag(link.getAttribute('data-tag'));
			}
			else if (link.hasAttribute('data-close-box'))
			{
				toggleBox(link.getAttribute('data-close-box'), Number(link.getAttribute('data-close-value')));
			}
		});
	}
});
