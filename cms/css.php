<?php

/*	cms/css.php is a dead endpoint, and it has been answering HTTP 500 to
	every request since the initial import.
	
	What it used to be: a "screen.css.php"-style dynamic stylesheet from the
	original Pika danio codebase -- a CSS body carrying %%[base_url]%% tags,
	rendered through pl_template() with the script itself as the template
	file and served as text/css. That CSS body is not in this repository. The
	file has held nothing but the seven-line bootstrap since 16577e89, so even
	a working version would emit its own PHP source as a stylesheet. Nothing
	in cms/, docker/, e2e/ or tests/ links to it or includes it.
	
	Why it failed: line 2 was chdir(".."), which ran before pika_init().
	pika_init() sets a RELATIVE include_path, './app/lib:./app/extralib:.',
	so the library directory only resolves while the working directory is
	cms/. After the chdir the working directory is the document root, which
	has no app/lib, and the next thing pika_init() does is require pl.php:
	
		Fatal error: Uncaught Error: Failed opening required 'pl.php'
		(include_path='./app/lib:./app/extralib:.:/usr/local/lib/php')
		in cms/pika-danio.php:844
	
	This is not a page and there is no stylesheet left to render, so it
	answers a plain 404 instead of booting the framework in order to crash.
	Deleting the file would be equally correct; the stub is kept so the URL
	has a documented answer rather than disappearing silently, and so this
	note stays with it.
*/

http_response_code(404);
header('Content-Type: text/html; charset=utf-8');
echo "<!doctype html><html lang=\"en\"><head><title>Not Found</title></head>"
	. "<body><main><h1>Not Found</h1><p>This URL is not a page.</p></main></body></html>";
exit();
