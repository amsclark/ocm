document.addEventListener('DOMContentLoaded', function ()
{
	var lists = document.querySelectorAll('.js-checkbox-list');
	for (var i = 0; i < lists.length; i++)
	{
		if (lists[i].getAttribute('data-check-bound') === '1')
		{
			continue;
		}
		lists[i].setAttribute('data-check-bound', '1');
		lists[i].addEventListener('click', function (e)
		{
			var field = this.getAttribute('data-field');
			if (e.target.matches('input[type="checkbox"]'))
			{
				update_checkbox_list(e.target.name, field);
			}
			var link = e.target.closest('a[data-check-action]');
			if (link && this.contains(link))
			{
				e.preventDefault();
				switch (link.getAttribute('data-check-action'))
				{
					case 'all':
						checkAll(this.id, field);
						break;
					case 'none':
						checkNone(this.id, field);
						break;
					case 'invert':
						checkInvert(this.id, field);
						break;
				}
			}
		});
	}
});
