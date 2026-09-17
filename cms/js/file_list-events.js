(function ()
{
	if (window.pikaFileListEventsLoaded)
	{
		return;
	}
	window.pikaFileListEventsLoaded = true;
	document.addEventListener('click', function (e)
	{
		var control = e.target.closest('[data-file-action]');
		if (!control || !control.closest('.js-file-list'))
		{
			return;
		}
		var action = control.getAttribute('data-file-action');
		var args = JSON.parse(control.getAttribute('data-file-args'));
		switch (action)
		{
			case 'list':
				e.preventDefault();
				fileList.apply(window, args);
				break;
			case 'edit':
				e.preventDefault();
				editFile.apply(window, args);
				break;
			case 'delete':
				e.preventDefault();
				confirmDeleteFile.apply(window, args);
				break;
			case 'description':
				setDescription(Number(args[0]));
				break;
			case 'select':
				if (e.target.matches('input[type="radio"]'))
				{
					updateCurrentDoc.apply(window, args);
				}
				break;
		}
	});
})();
