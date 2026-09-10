<?php

function pika_error($errno = null, $errstr = null, $errfile = null, $errline = null)
{
	
	
	$error_output = '';
	
	// The operator gets the whole detail, in the server log, always.
	pl_log_error('pika_error',"[{$errno}] {$errstr} in {$errfile}:{$errline}");
	
	/*	The browser gets it only when this installation is in debug mode.
		Before, every authenticated user was shown the failing file path, the
		line number and -- because trigger_error() calls all over the tree put
		the statement in the message -- the SQL. That is a map of the server
		and its schema handed to whoever provokes an error.
		
		display_errors Off, which is what the shipped Docker image sets, is
		enough to keep it off. See pl_is_debug_mode() in app/lib/pl.php.
	*/
	$debug_mode = pl_is_debug_mode();
	$generic_message = 'The server encountered an internal error and could not complete your request. Please contact your administrator.';
	
	// Every value below is attacker-influenced -- request headers, the query
	// string, the POST body -- and templates/unavailable.html renders them
	// raw, so the error page reflected whatever the request carried. The
	// template engine does not escape anything by default. Debug mode is the
	// kind of switch that gets left on, so escape either way.
	$esc = function ($v) {
		return pl_html_escape($v);
	};
	
	$a = array('action' => 'NONE', 'screen' => 'NONE', 'HTTP_REFERER' => 'NOT SET', 'QUERY_STRING' => 'NONE');
	
	if ($debug_mode)
	{
		$a['message'] = $esc($errstr);
		$a['file'] = $esc($errfile);
		$a['line'] = $esc($errline);
		if(isset($_REQUEST['action'])) {
			$a['action'] = $esc($_REQUEST['action']);
		}if(isset($_REQUEST['screen'])) {
			$a['screen'] = $esc($_REQUEST['screen']);
		}if(isset($_SERVER['HTTP_REFERER'])) {
			$a['HTTP_REFERER'] = $esc($_SERVER['HTTP_REFERER']);
		}if(isset($_SERVER['REQUEST_METHOD'])) {
			$a['REQUEST_METHOD'] = $esc($_SERVER['REQUEST_METHOD']);
		}if(isset($_SERVER['REMOTE_ADDR'])) {
			$a['REMOTE_ADDR'] = $esc($_SERVER['REMOTE_ADDR']);
		}if(isset($_SERVER['HTTP_USER_AGENT'])) {
			$a['HTTP_USER_AGENT'] = $esc($_SERVER['HTTP_USER_AGENT']);
		}if(isset($_SERVER['SERVER_NAME'])) {
			$a['SERVER_NAME'] = $esc($_SERVER['SERVER_NAME']);
		}if(isset($_SERVER['SERVER_SOFTWARE'])) {
			$a['SERVER_SOFTWARE'] = $esc($_SERVER['SERVER_SOFTWARE']);
		}if(isset($_SERVER['REQUEST_URI'])) {
			$a['REQUEST_URI'] = $esc($_SERVER['REQUEST_URI']);
		}if(isset($_SERVER['QUERY_STRING']) && $_SERVER['QUERY_STRING']) {
			$a['QUERY_STRING'] = $esc($_SERVER['QUERY_STRING']);
		}
	}
	
	else
	{
		// Blank every field unavailable.html would render, so the generic
		// page carries no path, no address and no request detail.
		$a['message'] = $generic_message;
		$a['file'] = '';
		$a['line'] = '';
		$a['REQUEST_METHOD'] = '';
		$a['REMOTE_ADDR'] = '';
		$a['HTTP_USER_AGENT'] = '';
		$a['SERVER_NAME'] = '';
		$a['SERVER_SOFTWARE'] = '';
		$a['REQUEST_URI'] = '';
	}

	require_once('pikaSettings.php');
	require_once('pikaAuth.php');
	require_once('pikaAuthHttp.php');
	$settings = pikaSettings::getInstance();
	
	// Verify the user is logged into pika
	
	
	
	// 3 possibilities (logged in/not logged in/no security)
	if(defined('PL_DISABLE_SECURITY'))
	{
		$error_output = $debug_mode
			? $esc($errstr) . ' Line: ' . $esc($errline) . ' File:' . $esc($errfile)
			: $generic_message;
	}
	elseif
	((defined('PL_HTTP_SECURITY') && pikaAuthHttp::getInstance()->isAuthorized()) || pikaAuth::getInstance()->isAuthorized()) 
	{
		$template = new pikaTempLib('templates/unavailable.html',$a);
		$main_html['content'] = $template->draw();
		$main_html['nav'] = "<a href=\"{$settings['base_url']}\">Pika Home</a>";
		$main_html['page_title'] = "Pika Error";
		$default_template = new pikaTempLib('templates/default.html',$main_html);
		$error_output = $default_template->draw();
	}
	else 
	{
		$html['messages'] = $debug_mode
			? $esc($errno . ': ' . $errstr)
			: $generic_message;
		// auth_id can be undefined when an error fires before the session is
		// started, and the notice for reading it would itself be rendered
		// into this page.
		$html['auth_id'] = isset($_SESSION['auth_id']) ? $_SESSION['auth_id'] : '';
		$default_template = new pikaTempLib('templates/login-form.html',$html);
		if(browser_is_mobile())
		{
			$default_template = new pikaTempLib('m/login-form.html',$html);
		}
		$error_output = $default_template->draw();	
	}
	
	
	
	
	
	return $error_output;
}

?>