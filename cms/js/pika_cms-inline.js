	// Create code for sfw() a.k.a. the set_fund wrapper.
function sfw(val, menu)
{
	menu = menu || document.querySelector('.js-pika-case-funding');
	var funding = JSON.parse(menu.getAttribute('data-funding'));
	var project = JSON.parse(menu.getAttribute('data-project'));
	var lsc_elig = JSON.parse(menu.getAttribute('data-lsc-elig'));
	return set_fund(funding[val], project[val], lsc_elig[val]);
}

document.addEventListener('DOMContentLoaded', function ()
{
	var menus = document.querySelectorAll('.js-pika-case-funding');
	for (var i = 0; i < menus.length; i++)
	{
		if (menus[i].getAttribute('data-pika-funding-bound'))
		{
			continue;
		}
		menus[i].setAttribute('data-pika-funding-bound', '1');
		menus[i].addEventListener('change', function ()
		{
			sfw(this.value, this);
		});
	}
});
