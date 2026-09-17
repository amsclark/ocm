(function()
{
	document.querySelector('.megapartyreport-move-up').addEventListener('click', function()
	{
		move_up();
	});
	document.querySelector('.megapartyreport-move-down').addEventListener('click', function()
	{
		move_down();
	});
	document.querySelector('.megapartyreport-run').addEventListener('click', function()
	{
		highlight_all_fo();
	});
	document.querySelector('.megapartyreport-load').addEventListener('click', function(e)
	{
		e.preventDefault();
		var sourceForm = document.forms[this.getAttribute('data-source-form')];
		load_report(this.getAttribute('data-report-form'), sourceForm.elements[this.getAttribute('data-report-id-field')].value);
	});
	document.querySelector('.megapartyreport-save').addEventListener('click', function(e)
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

  // handling of adding relation_codes to the field ordering.
var relation_checkboxes = document.querySelectorAll('.party_types input[type=checkbox]');
for (var i = 0; i < relation_checkboxes.length; i++)
{
	relation_checkboxes[i].addEventListener('change', function()
	{
		handle_relation_codes_selection();
	});
}

function handle_relation_codes_selection()
{
	add_option_rel("fo", 'conflict.relation_code', 'Party Type');
}

function add_option_rel(menu_name, field_name, field_text)
{
	var container = document.getElementById(menu_name);
	var is_found = false;
	var checked_relation_checkboxes = [];
	for (var h = 0; h < relation_checkboxes.length; h++)
	{
		if (relation_checkboxes[h].checked)
		{
			checked_relation_checkboxes.push(relation_checkboxes[h]);
		}
	}
	if (container.length)
	{
		for (var i = 0; i < container.length; i++)
		{
			if (container.options[i].value == field_name)
			{
				if (checked_relation_checkboxes.length == 0)
				{
					container.options[i] = null;
				}
				is_found = true;
				break;
			}
		}
	}
	if (is_found == false)
	{
		var addIndex = container.length;
		container.options[addIndex] = new Option(field_text, field_name);
	}
}
