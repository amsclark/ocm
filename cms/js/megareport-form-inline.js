(function()
{
	document.querySelector('.megareport-move-up').addEventListener('click', function()
	{
		move_up();
	});
	document.querySelector('.megareport-move-down').addEventListener('click', function()
	{
		move_down();
	});
	document.querySelector('.megareport-run').addEventListener('click', function()
	{
		highlight_all_fo();
	});
	document.querySelector('.megareport-load').addEventListener('click', function(e)
	{
		e.preventDefault();
		var sourceForm = document.forms[this.getAttribute('data-source-form')];
		load_report(this.getAttribute('data-report-form'), sourceForm.elements[this.getAttribute('data-report-id-field')].value);
	});
	document.querySelector('.megareport-save').addEventListener('click', function(e)
	{
		e.preventDefault();
		save_report(this.getAttribute('data-report-form'), this.getAttribute('data-name-field'));
		var target = this.getAttribute('data-reload-target');
		setTimeout(function()
		{
			reload(target);
		}, Number(this.getAttribute('data-reload-delay')));
	});
})();
