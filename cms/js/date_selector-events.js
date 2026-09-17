(function ()
{
	if (window.pikaDateSelectorEventsLoaded)
	{
		return;
	}
	window.pikaDateSelectorEventsLoaded = true;
	document.addEventListener('click', function (e)
	{
		var link = e.target.closest('a[data-date-action]');
		var calendar = link && link.closest('.js-date-selector');
		if (!calendar)
		{
			return;
		}
		var field = JSON.parse(calendar.getAttribute('data-field-name'));
		var container = JSON.parse(calendar.getAttribute('data-container-name'));
		switch (link.getAttribute('data-date-action'))
		{
			case 'month':
				date_selector(field, container, link.getAttribute('data-month'), link.getAttribute('data-year'));
				break;
			case 'select':
				selectDate(field, link.getAttribute('data-date'), container);
				break;
			case 'close':
				closeCalendar(container);
				break;
		}
	});
})();
