var unsaved_changes = false;
function setConfirmUnload(on)
{
	window.onbeforeunload = (on) ? unloadMessage : null;
}

function unloadMessage()
{
	return 'You have entered new data on this page.  If you navigate away from this page without first saving your data, the changes will be lost.';
}

document.addEventListener('DOMContentLoaded', function ()
{
	var inputs = document.querySelectorAll('form[name="fc"] input, form[name="fc"] select, form[name="fc"] textarea, form[name="fc"] button');
	for (var i = 0; i < inputs.length; i++)
	{
		inputs[i].addEventListener('change', function ()
		{
			setConfirmUnload(true);
		});
	}
	var submits = document.querySelectorAll('form[name="fc"] input[type="submit"], form[name="fc"] button[type="submit"], form[name="fc"] button:not([type])');
	for (var j = 0; j < submits.length; j++)
	{
		submits[j].addEventListener('click', function ()
		{
			setConfirmUnload(false);
		});
	}
});
