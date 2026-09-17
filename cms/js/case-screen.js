/*	Behaviour for the case summary sidebar (subtemplates/case_screen.html).

	Everything here used to be an inline on* attribute in that template, which
	is what makes script-src 'unsafe-inline' necessary in the
	Content-Security-Policy. 'unsafe-inline' lets an injected <script> run, so
	it removes most of the protection a CSP is there to give.

	The "remove this party" confirmations are the interesting case. The party's
	name cannot be written into a JavaScript string literal in the template: an
	apostrophe in somebody's name would close the literal early. The template
	worked around that by setting a global in a one-line <script> block per
	party and reading the global from the onSubmit attribute. A data- attribute
	does the same job without any inline script: the value goes through the
	template layer's normal HTML escaping, which escapes quotes, and it is read
	back here as a string that was never parsed as code.
*/

document.addEventListener('DOMContentLoaded', function ()
{
	/*	The popup timer. The link works as an ordinary link for anyone
		without JavaScript, so the handler cancels the navigation only once
		it has opened the popup itself.
	*/
	var timers = document.querySelectorAll('.js-popup-timer');

	for (var i = 0; i < timers.length; i++)
	{
		timers[i].addEventListener('click', function (e)
		{
			popUp({ url: this.href, name: 'popUpTimer' });
			e.preventDefault();
		});
	}

	/*	"remove <party> from this case". One form per party.
	*/
	var forms = document.querySelectorAll('.js-confirm-remove-party');

	for (var j = 0; j < forms.length; j++)
	{
		forms[j].addEventListener('submit', function (e)
		{
			var name = this.getAttribute('data-party-name');

			if (!confirm('Are you sure you want to remove ' + name + ' from this case?'))
			{
				e.preventDefault();
			}
		});
	}
});
