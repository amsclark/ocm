// Report field lists: replace checkbox onclick arguments with a delegated listener.
document.addEventListener('DOMContentLoaded', function ()
{
	document.addEventListener('change', function (event)
	{
		var field = event.target;
		if (field && field.classList && field.classList.contains('js-field-list-toggle'))
		{
			update(field.getAttribute('data-pair'), field.getAttribute('data-label'));
		}
	});
});
