document.addEventListener('DOMContentLoaded', function ()
{
	var handlers = [
		['.js-case-elig-persons', 'change', ph_change],
		['.js-case-elig-wage', 'change', calcWage],
		['.js-case-elig-send-grid', 'click', sendToGrid],
		['.js-case-elig-annual', 'change', annual_change],
		['.js-case-elig-asset', 'change', asset_change],
		['.js-case-elig-poverty', 'click', calc_poverty]
	];
	for (var i = 0; i < handlers.length; i++)
	{
		var elements = document.querySelectorAll(handlers[i][0]);
		for (var j = 0; j < elements.length; j++)
		{
			elements[j].addEventListener(handlers[i][1], handlers[i][2]);
		}
	}

	var guideLinks = document.querySelectorAll('.js-case-elig-guide');
	for (var k = 0; k < guideLinks.length; k++)
	{
		guideLinks[k].addEventListener('click', function (e)
		{
			e.preventDefault();
			popUp({url: this.href, name: this.getAttribute('data-popup-name')});
		});
	}
});
