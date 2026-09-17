document.addEventListener('DOMContentLoaded', function ()
{
	var truncate = document.querySelector('.js-truncate-ssns');
	if (truncate)
	{
		truncate.addEventListener('click', function (e)
		{
			if (!confirm('Are you sure you want to shorten all SSNs to the last four digits?  This operation can not be undone.') || !confirm('Click OK to truncate all SSNs.'))
			{
				e.preventDefault();
			}
		});
	}
	var remove = document.querySelector('.js-remove-ssns');
	if (remove)
	{
		remove.addEventListener('click', function (e)
		{
			if (!confirm('Are you sure you want to remove all SSNs?  This operation can not be undone.') || !confirm('Click OK to delete all SSNs.'))
			{
				e.preventDefault();
			}
		});
	}
});
