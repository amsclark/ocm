document.ws.summary.focus();

function setSmsVisibility()
{
	if (document.ws.case_id.value.length > 0)
	{
		document.getElementById("sms_reminders").style.display = "block";
	}
	else
	{
		document.getElementById("sms_reminders").style.display = "none";
	}
}

setSmsVisibility();

jQuery(document).ready(function()
{
	if (typeof jQuery.fn.datepicker === 'function')
	{
		jQuery("#act_date").datepicker();
	}
});

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
