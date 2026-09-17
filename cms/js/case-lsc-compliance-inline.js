// Case LSC compliance: replace the problem menu's inline onchange handler.
document.addEventListener('DOMContentLoaded', function ()
{
	var problemMenu = document.getElementById('problem');
	if (problemMenu)
	{
		problemMenu.addEventListener('change', function ()
		{
			problem_code_lookup(this.value);
		});
	}
});
