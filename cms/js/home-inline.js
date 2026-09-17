
function toggleMotd(id) {
	toggleDiv("motd-summary-"+id);
	toggleDiv("motd-content-"+id);
}

function toggleDiv(id) {
	var div = document.getElementById(id);
	if(div.style.display == "none") {
		div.style.display = "block";
	} else {
		div.style.display = "none";
	}
}

document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-hide-motd');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function (e)
		{
			toggleMotd(this.getAttribute('data-motd-id'));
			e.preventDefault();
		});
	}
});
