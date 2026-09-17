// Pro bono attorneys: replace the ZIP field's inline onblur handler.
document.addEventListener('DOMContentLoaded', function ()
{
	var zip = document.getElementById('zip');
	if (zip)
	{
		zip.addEventListener('blur', function ()
		{
			zipcode_lookup(this.value);
		});
	}
});
