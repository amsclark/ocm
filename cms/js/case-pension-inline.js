document.addEventListener('DOMContentLoaded', function ()
{
	var issueFields = document.querySelectorAll('.js-case-pension-issue');
	for (var i = 0; i < issueFields.length; i++)
	{
		issueFields[i].addEventListener('change', function ()
		{
			issue_code_lookup(this);
		});
	}

	var annuityBlurFields = document.querySelectorAll('.js-case-pension-annuity-blur');
	for (var j = 0; j < annuityBlurFields.length; j++)
	{
		annuityBlurFields[j].addEventListener('blur', function ()
		{
			total_annuities();
		});
	}

	var annuityChangeFields = document.querySelectorAll('.js-case-pension-annuity-change');
	for (var k = 0; k < annuityChangeFields.length; k++)
	{
		annuityChangeFields[k].addEventListener('change', function ()
		{
			total_annuities();
		});
	}

	var calculationTypes = document.querySelectorAll('.js-case-pension-calculation-type');
	for (var l = 0; l < calculationTypes.length; l++)
	{
		calculationTypes[l].addEventListener('change', function ()
		{
			display_recovery_calulator(this.value);
		});
	}

	var levelButtons = document.querySelectorAll('.js-case-pension-calculate-level');
	for (var m = 0; m < levelButtons.length; m++)
	{
		levelButtons[m].addEventListener('click', function ()
		{
			runPPALevel();
			total_annuities();
		});
	}

	var calculateButtons = document.querySelectorAll('.js-case-pension-calculate');
	for (var n = 0; n < calculateButtons.length; n++)
	{
		calculateButtons[n].addEventListener('click', function ()
		{
			runPPA();
			total_annuities();
		});
	}
});
