/*	Types the dashes into a social security number as it is entered.

	This lived in an inline <script> block in every template that drew an SSN
	field, and each field carried onkeyup="pika_ssn(this);". Both halves are
	inline JavaScript, which is what makes script-src 'unsafe-inline'
	necessary in the Content-Security-Policy, so both moved here.

	A field opts in by carrying class="js-ssn-mask". pika_ssn() stays a global
	function because it is small, self-contained, and other templates may
	still call it directly.
*/

var old_ssn_length = 0;

function pika_ssn(what)
{
	if (what.value.length == 3 && old_ssn_length == 2)
	{
		what.value += '-';
	}

	if (what.value.length == 6 && old_ssn_length == 5)
	{
		what.value += '-';
	}

	old_ssn_length = what.value.length;
}

document.addEventListener('DOMContentLoaded', function ()
{
	var fields = document.querySelectorAll('.js-ssn-mask');

	for (var i = 0; i < fields.length; i++)
	{
		fields[i].addEventListener('keyup', function ()
		{
			pika_ssn(this);
		});
	}
});
