document.addEventListener('DOMContentLoaded', function ()
{
	var tabs = document.querySelectorAll('.js-case-tab');
	for (var i = 0; i < tabs.length; i++)
	{
		tabs[i].addEventListener('click', function (e)
		{
			if (typeof window.setConfirmUnload == 'function')
			{
				setConfirmUnload(false);
			}
			document.forms.ws.screen.value = this.getAttribute('data-screen');
			document.forms.ws.submit();
			e.preventDefault();
		});
	}
});
