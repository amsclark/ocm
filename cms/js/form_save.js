/*	This file used to be markup, not JavaScript: a <script src> for jQuery and
	a <script> block around the code below, written so that pb_attorneys.php
	could file_get_contents() it and echo it into the page. That is an inline
	script block, and script-src no longer allows one unless it carries the
	response's nonce, so the page loads this with a <script src> instead and
	the file holds plain JavaScript.

	The jQuery include went with the wrapper. templates/default.html loads
	js/jquery.min.js in the head, above the point where the page content is
	drawn, so the second copy was already redundant.
*/

var unsaved_changes = false;

function setConfirmUnload(on)
{
	window.onbeforeunload = (on) ? unloadMessage : null;
}

function unloadMessage()
{
	return 'You have entered new data on this page.  If you navigate away from this page without first saving your data, the changes will be lost.';
}

// 2013-07-11 AMW - Changed selector syntax to work with jQuery 2.
$(document).ready(function() {
	$('form[name="ws"] :input').change(function () {
		setConfirmUnload(true); }); // Prevent accidental navigation away
	$('form[name="ws"] :submit').click(function () {
		setConfirmUnload(false); }); // They've clicked sav - navigate away
});
