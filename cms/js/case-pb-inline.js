document.addEventListener('DOMContentLoaded', function ()
{
	var feeFields = ['atty_fee_normal', 'atty_fee_to_client'];
	for (var k = 0; k < feeFields.length; k++)
	{
		var feeField = document.getElementById(feeFields[k]);
		if (feeField)
		{
			feeField.addEventListener('blur', function ()
			{
				calcDifference();
			});
		}
	}

	var referralLinks = document.querySelectorAll('.js-case-pb-ref-date');
	for (var i = 0; i < referralLinks.length; i++)
	{
		referralLinks[i].addEventListener('click', function (e)
		{
			e.preventDefault();
			set_ref_date();
		});
	}

	var closeLinks = document.querySelectorAll('.js-case-pb-close-date');
	for (var j = 0; j < closeLinks.length; j++)
	{
		closeLinks[j].addEventListener('click', function (e)
		{
			e.preventDefault();
			set_close();
		});
	}
});
