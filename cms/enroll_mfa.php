<?php
/**********************************/
/* Pika CMS						  */ 
/* (C) 2011 Pika Software, LLC.   */
/* http://pikasoftware.com        */
/**********************************/

/*	enroll_mfa.php -- one-time self-service MFA enrollment.
	
	Reached when pl_mfa_enroll_gate() bounces a logged-in user whose account
	has MFA turned on but no secret it can use. The user adds the key to an
	authenticator app, confirms one code, and only then is the secret stored.
	It is never emailed and never shown to an administrator.
	
	How the pending secret survives the round trip: this application's session
	save handler is a no-op, so $_SESSION does not persist across requests and
	cannot hold it. It is carried GET->POST as its own ciphertext in a hidden
	field instead. That adds no exposure, because the cleartext key is already
	on the page for the user to type into their app; the ciphertext cannot be
	forged without the server's key; and the result is always written to the
	user the session says is signed in, never to an id taken from the form.
*/

require_once ('pika-danio.php');
pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

require_once('pikaTempLib.php');
require_once('pikaCrypto.php');
require_once('app/lib/pikaMfaEnroll.php');

$base_url = (string) pl_settings_get('base_url');

$auth_row = pikaAuth::getInstance()->getAuthRow();
$uid = (is_array($auth_row) && isset($auth_row['user_id'])) ? (int) $auth_row['user_id'] : 0;
$username = (is_array($auth_row) && isset($auth_row['username'])) ? (string) $auth_row['username'] : '';

if ($uid <= 0)
{
	// Not signed in. pika_init() has already shown the login form for a
	// request with no session at all, so this is belt and braces.
	header('Location: ' . $base_url . '/');
	exit();
}

if (!pl_mfa_user_must_enroll($uid))
{
	// Nothing to enroll: MFA is off for this account, or it already has a
	// working secret. Do not hand out a new key to somebody who could then
	// replace a factor they are already holding.
	header('Location: ' . $base_url . '/');
	exit();
}

$error = '';
$secret = null;		// base32 cleartext, for THIS render
$cipher = null;		// pl_totp_encrypt() of $secret; round-trips in the form

if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	$token = isset($_POST['enroll_token']) ? (string) $_POST['enroll_token'] : '';
	$code = isset($_POST['mfa_code']) ? preg_replace('/[^0-9]/', '', (string) $_POST['mfa_code']) : '';
	$pending = (strlen($token) > 0) ? pl_totp_decrypt($token) : false;
	
	/*	Throttle the confirm step the way the login form is throttled.
		Without it this is an unlimited oracle against a six-digit code
		space: the secret comes back in the hidden field, so whoever holds
		the session can resubmit the same token with guessed codes at
		request speed and enrol a factor of their own choosing. Keyed per
		user so one account's lockout does not spill onto another; the
		per-address key that pl_auth_rate_limit_keys() adds catches an
		attacker rotating the user id.
	*/
	$rl_keys = pl_auth_rate_limit_keys('enroll_mfa:' . $uid);
	$locked = pl_auth_rate_limit_first_locked($rl_keys);
	
	if (!is_null($locked))
	{
		pl_audit('user.totp_enroll_locked', 'user', $uid, array('username' => $username), $uid, $username);
		$error = 'Too many incorrect codes. Please wait a few minutes and try again.';
	}
	
	/*	pl_totp_verify_window() rather than pl_totp_verify_once(): the secret
		being confirmed here is brand new, so a totp_last_used left behind by
		an earlier enrollment on this account bears no relation to it and
		would refuse every code -- and with the enrollment gate in front of
		every page, that locks the user out of the application with no way
		forward. The replay bound is seeded below instead.
	*/
	elseif (false !== $pending && strlen((string) $pending) > 0
		&& false !== pl_totp_verify_window((string) $pending, $code))
	{
		$stored = false;
		
		try
		{
			DB::preparedQuery(
				'UPDATE users SET totp_enabled = 1, totp_secret = ?, totp_last_used = ? WHERE user_id = ? LIMIT 1',
				array($token, (int) floor(time() / 30), $uid)
			);
			$stored = true;
		}
		
		catch (Exception $e)
		{
			error_log('enroll_mfa: storing the secret for user_id ' . $uid . ' failed: ' . $e->getMessage());
		}
		
		if ($stored)
		{
			/*	The window is marked used as part of the same write. The code
				the user typed here must not be usable again at the login
				form inside its own 30 seconds.
			*/
			pl_auth_rate_limit_reset_all($rl_keys);
			pl_audit('user.totp_self_enrolled', 'user', $uid, array('username' => $username), $uid, $username);
			header('Location: ' . $base_url . '/');
			exit();
		}
		
		$error = 'The code was correct, but the setting could not be saved. Please try again, or contact your administrator.';
	}
	
	if ('' === $error)
	{
		// A genuine wrong code. Count it against both keys; the next attempt
		// is what meets the lockout branch above.
		pl_auth_rate_limit_record_failure_all($rl_keys);
		$error = 'That code did not match. Make sure this account is added to your authenticator app, then enter the code it is showing now.';
	}
	
	/*	Keep the same key on a retry so the user does not have to add it to
		their app again. That holds on a lockout too: the throttle is what
		stops the guessing, and issuing a new key would only inconvenience
		the legitimate user.
	*/
	if (false !== $pending && strlen((string) $pending) > 0)
	{
		$secret = (string) $pending;
		$cipher = $token;
	}
}

if (is_null($secret))
{
	$secret = pl_totp_generate_secret();
	$cipher = pl_totp_encrypt($secret);
}

$html = array();
$html['page_title'] = 'Set up MFA';

if (false === $cipher)
{
	/*	No usable encryption key on this server. Say so plainly rather than
		handing out a key that cannot be stored, which would loop the user
		through this page forever.
	*/
	$html['otpauth_uri'] = '';
	$html['totp_secret_cleartext'] = '';
	$html['enroll_token'] = '';
	$html['error_msg'] = '<div class="alert alert-error">Multi-factor authentication is not '
		. 'fully configured on this server: the encryption key is missing. Please contact '
		. 'your administrator.</div>';
	
	$template = new pikaTempLib('templates/enroll-mfa.html',$html);
	echo $template->draw();
	exit();
}

$owner_name = (string) pl_settings_get('owner_name');
$issuer = (strlen($owner_name) > 0) ? $owner_name : 'Pika CMS';
$label = $issuer . ':' . $username;
$otpauth_uri = 'otpauth://totp/' . rawurlencode($label)
	. '?secret=' . rawurlencode($secret)
	. '&issuer=' . rawurlencode($issuer);

$html['otpauth_uri'] = pl_html_escape($otpauth_uri);
$html['totp_secret_cleartext'] = pl_html_escape_label($secret);
$html['enroll_token'] = pl_html_escape((string) $cipher);
$html['error_msg'] = ('' !== $error)
	? '<div class="alert alert-error">' . pl_html_escape_label($error) . '</div>'
	: '';

$template = new pikaTempLib('templates/enroll-mfa.html',$html);
echo $template->draw();
exit();
