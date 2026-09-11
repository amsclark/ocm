--	doc_force_download
--
--	cms/documents.php serves a stored document inline only when its content
--	type is one that a browser renders but cannot run script from: a PDF,
--	plain text, or a raster image. Anything else -- HTML, XML, SVG, an unknown
--	type -- downloads instead, because the content type is whatever the
--	uploading browser claimed and an inline text/html response executes in the
--	application's own origin.
--
--	Turn this on to give up in-browser preview entirely and make every
--	document an attachment. It is off by default: the allowlist is the part
--	that closes the vulnerability, and previewing a client's scanned PDF
--	without downloading it is how the application has always worked.
--
--	INSERT IGNORE so re-running this on an install that already has the row
--	does not reset an operator's choice.

INSERT IGNORE INTO settings (label, value) VALUES
	('doc_force_download', '0');
