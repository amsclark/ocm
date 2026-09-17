/*	The mobile home page's message board.

	The "View Full Text" link used to carry an onclick attribute, which is
	one of the things that makes script-src 'unsafe-inline' necessary. The
	message id now travels in data-motd-id and the handler lives here.

	toggleMotd and toggleDiv are defined here rather than called from
	somewhere else. The onclick this replaced called toggleMotd, but nothing
	the mobile home page loads has ever defined it: m/index.php renders
	m/home.html inside m/default.html, and the only definition in the mobile
	tree is in m/messages.html, a different page. So the link has been
	throwing for as long as it has existed. Moving the handler out is the
	point at which that becomes fixable, so it is fixed.
*/

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

function toggleMotd(id)
{
	toggleDiv("motd-summary-" + id);
	toggleDiv("motd-content-" + id);
}

document.addEventListener('DOMContentLoaded', function ()
{
	var els = document.querySelectorAll('.js-index-toggle-motd');
	
	for (var i = 0; i < els.length; i++)
	{
		els[i].addEventListener('click', function (e)
		{
			e.preventDefault();
			toggleMotd(this.getAttribute('data-motd-id'));
		});
	}
});
