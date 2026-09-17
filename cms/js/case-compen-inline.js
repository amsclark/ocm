/*	The Delete link on the compensation tab used to carry
	onclick="confirm('Are you sure you wish to delete this entry?');" with no
	return, so the answer was computed and thrown away: Cancel deleted the
	entry just the same as OK. That is a data-loss bug and not worth carrying
	forward, so this handler cancels the navigation when the answer is no,
	which is what the dialog has always claimed to do. The sibling
	js/case_delete-inline.js does the same for the case Delete link.
*/
document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-case-compen-confirm');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function (e)
		{
			if (!confirm(this.getAttribute('data-confirm')))
			{
				e.preventDefault();
			}
		});
	}
});
