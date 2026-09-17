/*	Replaces the monthly benefit onchange attributes in case-lsac.html.
*/
document.addEventListener('DOMContentLoaded', function ()
{
	var protectedBenefit = document.querySelector('.js-annual-benefit-protected');
	if (protectedBenefit)
	{
		protectedBenefit.addEventListener('change', function ()
		{
			annual_benefit_protected_change();
		});
	}

	var obtainedBenefit = document.querySelector('.js-annual-benefit-obtained');
	if (obtainedBenefit)
	{
		obtainedBenefit.addEventListener('change', function ()
		{
			annual_benefit_obtained_change();
		});
	}
});
