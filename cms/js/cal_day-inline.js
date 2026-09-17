function checkAll()
{
	var i = document.act_update_bulk.getAttribute('data-item-count');

	for (j = 0; j < i; j++)
	{
		k = (j * 2);
		document.act_update_bulk.elements[k].checked = true;
	}
}

function uncheckAll()
{
	var i = document.act_update_bulk.getAttribute('data-item-count');

	for (j = 0; j < i; j++)
	{
		k = (j * 2);
		document.act_update_bulk.elements[k].checked = false;
	}
}

document.querySelectorAll('.cal_day-popup-timer').forEach(function(link)
{
	link.addEventListener('click', function(e)
	{
		e.preventDefault();
		popUp({url: this.href, name: this.getAttribute('data-popup-name')});
	});
});

document.querySelectorAll('.cal_day-check-all').forEach(function(link)
{
	link.addEventListener('click', function(e)
	{
		e.preventDefault();
		checkAll();
	});
});

document.querySelectorAll('.cal_day-uncheck-all').forEach(function(link)
{
	link.addEventListener('click', function(e)
	{
		e.preventDefault();
		uncheckAll();
	});
});
