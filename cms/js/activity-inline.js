document.ws.summary.focus();

(function()
{
	var links = document.querySelectorAll('.activity-text-highlight');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function(e)
		{
			e.preventDefault();
			toggleBox(this.getAttribute('data-target'), Number(this.getAttribute('data-toggle-state')));
		});
	}
})();

if (document.ws.getAttribute('data-datepicker'))
{
	jQuery(document).ready(function()
	{
		if (typeof jQuery.fn.datepicker === 'function')
		{
			jQuery(document.getElementById(document.ws.getAttribute('data-datepicker'))).datepicker();
		}
	});
}
