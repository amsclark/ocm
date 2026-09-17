/*	Replaces the Save, Next Tab onclick attributes in case-address.html,
	case-conflict.html, case-info.html, and case-lsc-compliance.html.
*/
document.addEventListener('DOMContentLoaded', function ()
{
	var buttons = document.querySelectorAll('.js-save-next-tab');
	for (var i = 0; i < buttons.length; i++)
	{
		buttons[i].addEventListener('click', function ()
		{
			document.forms.ws.screen.value = this.getAttribute('data-next-screen');
		});
	}
});
