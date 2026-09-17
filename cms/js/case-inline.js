var unsaved_changes = false;
function setConfirmUnload(on)
{
	window.onbeforeunload = (on) ? unloadMessage : null;
}

function unloadMessage()
{
	return 'You have entered new data on this page.  If you navigate away from this page without first saving your data, the changes will be lost.';
}

// 2013-07-11 AMW - Changed selector syntax to work with jQuery 2.
document.addEventListener('DOMContentLoaded', function ()
{
	$('form[name="ws"] :input').change(function ()
	{
		setConfirmUnload(true);
	});
	$('form[name="ws"] :submit').click(function ()
	{
		setConfirmUnload(false);
	});
});
