document.querySelectorAll('.cal_adv-popup-timer').forEach(function(link)
{
	link.addEventListener('click', function(e)
	{
		e.preventDefault();
		popUp({url: this.href, name: this.getAttribute('data-popup-name')});
	});
});
