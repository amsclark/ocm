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

document.addEventListener('DOMContentLoaded', function ()
{
	/*	activity.php used to concatenate these two into one onchange
		attribute, funding first, and each half only when its own condition
		held. The conditions now reach the browser as classes, so a menu may
		carry either, both or neither. Keep funding before SMS visibility:
		setFunding writes the funding field and setSmsVisibility reads the
		form to decide what to show.
	*/
	var fundingMenus = document.querySelectorAll('.js-set-funding');
	for (var f = 0; f < fundingMenus.length; f++)
	{
		fundingMenus[f].addEventListener('change', function ()
		{
			setFunding(this.value);
		});
	}

	var smsMenus = document.querySelectorAll('.js-set-sms-visibility');
	for (var s = 0; s < smsMenus.length; s++)
	{
		smsMenus[s].addEventListener('change', function ()
		{
			setSmsVisibility();
		});
	}

	var interviewLinks = document.querySelectorAll('.js-insert-interview');
	for (var i = 0; i < interviewLinks.length; i++)
	{
		interviewLinks[i].addEventListener('click', function (e)
		{
			insert_interview(document.ws.interviews.value);
			e.preventDefault();
		});
	}
});
