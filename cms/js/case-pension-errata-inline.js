// Pension errata: replace recovery fields' inline onblur handlers.
document.addEventListener('DOMContentLoaded', function ()
{
	var recoveryFields = ['recovery_annuity', 'recovery_distribution'];
	for (var i = 0; i < recoveryFields.length; i++)
	{
		var recoveryField = document.getElementById(recoveryFields[i]);
		if (recoveryField)
		{
			recoveryField.addEventListener('blur', function ()
			{
				total_recoveries();
			});
		}
	}
});
