document.addEventListener('DOMContentLoaded', function ()
{
	var buttons = document.querySelectorAll('.js-input-date-selector');
	for (var i = 0; i < buttons.length; i++)
	{
		buttons[i].addEventListener('click', function ()
		{
			openCalendar(JSON.parse(this.getAttribute('data-field-name')), JSON.parse(this.getAttribute('data-container-name')));
		});
	}
});
