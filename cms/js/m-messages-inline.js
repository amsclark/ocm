function toggleMotd(id)
{
	toggleDiv("motd-summary-"+id);
	toggleDiv("motd-content-"+id);
}

function toggleDiv(id)
{
	var div = document.getElementById(id);
	if (!div)
	{
		return;
	}
	if (div.style.display == "none")
	{
		div.style.display = "block";
	}
	else
	{
		div.style.display = "none";
	}
}

document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-toggle-mobile-motd');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function (e)
		{
			e.preventDefault();
			toggleMotd(this.getAttribute('data-motd-id'));
		});
	}
});
