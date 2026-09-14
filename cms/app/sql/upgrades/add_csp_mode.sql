--	csp_mode
--
--	Whether to send a Content-Security-Policy header, and whether it is
--	enforced. See pl_send_csp_header() in cms/app/lib/pl.php for the policy
--	itself and for why script-src and style-src still carry 'unsafe-inline'.
--
--	  enforce      send Content-Security-Policy (the default)
--	  report_only  send Content-Security-Policy-Report-Only instead; the
--	               browser logs violations and blocks nothing
--	  off          send neither header
--
--	A missing row reads as 'enforce', so an install that never opens the
--	system settings screen is still protected. This row exists only so the
--	setting appears on that screen with a value selected.
--
--	INSERT IGNORE so re-running this on an install that already has the row
--	does not reset an operator's choice.

INSERT IGNORE INTO settings (label, value) VALUES
	('csp_mode', 'enforce');
