<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

/*	Start an OpenID Connect sign-in.
	
	This endpoint generates the three values that make the round trip to the
	identity provider safe, stores them where the browser cannot reach them,
	and redirects:
	
	  state          ties the callback to this browser's session. Without it
	                 the callback accepts an authorization code delivered by
	                 anybody, which is how an attacker signs a victim's
	                 browser in as themselves.
	  nonce          ties the returned ID token to this redirect. Without it
	                 a token the provider issued for an earlier sign-in of the
	                 same user at the same client can be replayed here.
	  code_verifier  PKCE. Without it an authorization code intercepted
	                 anywhere between the provider and this server -- in a
	                 browser log, a proxy, a referrer header -- can be
	                 exchanged for tokens by whoever holds it.
	
	All three go into pika_sso_oidc_state, keyed on the session id, because
	pl_session_write() is a no-op in this application and $_SESSION does not
	survive the redirect.
	
	No session and no authorization: this is the front door.
*/

chdir('../..');

define('PL_DISABLE_SECURITY', true);

require_once('pika-danio.php');
pika_init();

require_once('pikaSsoOidc.php');

require_once('pikaSsoReauth.php');

/*	A sign-in starts with the browser following a link. The one POST this
	endpoint accepts is the step-up re-auth challenge in pl.php, which
	sends a signed-in SSO user back to the provider to prove who they are
	before a sensitive change goes through. Anything else is a caller that
	has confused this endpoint for the callback.
*/
$method = isset($_SERVER['REQUEST_METHOD']) ? (string) $_SERVER['REQUEST_METHOD'] : 'GET';

if ('GET' !== $method && 'POST' !== $method)
{
	header('HTTP/1.1 405 Method Not Allowed');
	header('Allow: GET, POST');
	header('Content-Type: text/plain; charset=utf-8');
	exit("GET or POST only.\n");
}

if ('POST' === $method && !isset($_POST['reauth_scope']))
{
	header('HTTP/1.1 405 Method Not Allowed');
	header('Allow: GET, POST');
	header('Content-Type: text/plain; charset=utf-8');
	exit("GET or POST only.\n");
}

$reason = '';
$config = pl_sso_config();

/*	404 rather than a message. A deployment that has not configured SSO
	should look to the outside exactly like one whose code does not have it,
	so that probing this path says nothing about the deployment.
*/
if (!pl_sso_ready($config, $reason))
{
	pl_sso_bail(404, $reason);
}

/*	Step-up re-auth intent, present only when pl_reauth_required() sent a
	signed-in SSO user here. Everything about it is checked now and kept
	server-side; none of it survives in the URL, so the value that comes
	back from the provider cannot be steered by whoever crafted the
	request.
*/
$reauth_scope  = '';
$reauth_return = '';

if (isset($_POST['reauth_scope']))
{
	/*	The CSRF token proves the POST came from this application's own
		challenge page. Without it any site could bounce a signed-in
		administrator through their provider and land a re-auth grant in
		their session.
	*/
	pl_csrf_check();
	
	$submitted_scope = (string) $_POST['reauth_scope'];
	
	if (!in_array($submitted_scope, pl_reauth_scopes(), true))
	{
		pl_sso_reauth_refuse('bad_scope', 'That action cannot be re-authenticated.');
	}
	
	/*	The session has to be signed in already, and signed in as an SSO
		account. Re-auth raises the assurance of a session that exists; it
		is never a way to create one.
	*/
	$session_user = pl_sso_reauth_session_user();
	
	if (is_null($session_user))
	{
		pl_sso_reauth_refuse('no_live_session', 'Your session has ended. Sign in again.');
	}
	
	if ('sso' !== $session_user['auth_method'] || 0 === strlen((string) $session_user['sso_subject']))
	{
		pl_sso_reauth_refuse('not_sso_user', 'This account does not sign in through an identity provider.');
	}
	
	$reauth_scope  = $submitted_scope;
	$reauth_return = pl_sso_reauth_sanitize_return(isset($_POST['reauth_return']) ? (string) $_POST['reauth_return'] : '');
}

try
{
	$discovery = pl_sso_discovery($config);
	
	/*	32 bytes from the CSPRNG for each. random_bytes() throws rather than
		returning weak output when the platform cannot deliver entropy, which
		is the behaviour this needs: a predictable state or nonce is worse than
		a sign-in that fails.
	*/
	$state    = pl_sso_base64url_encode(random_bytes(32));
	$nonce    = pl_sso_base64url_encode(random_bytes(32));
	$verifier = pl_sso_base64url_encode(random_bytes(32));
	
	pl_sso_state_put('state', $state);
	pl_sso_state_put('nonce', $nonce);
	pl_sso_state_put('code_verifier', $verifier);
	
	$params = array(
		'client_id'             => $config['client_id'],
		'response_type'         => 'code',
		'scope'                 => 'openid profile email',
		'redirect_uri'          => pl_sso_redirect_uri(),
		'state'                 => $state,
		'nonce'                 => $nonce,
		'code_challenge'        => pl_sso_base64url_encode(hash('sha256', $verifier, true)),
		'code_challenge_method' => 'S256'
	);
	
	if ('entra' === $config['provider'])
	{
		// Ask for the code in the query string. Entra's default for a web
		// application is the fragment, which never reaches the server.
		$params['response_mode'] = 'query';
	}
	
	/*	Google's hd parameter pins the sign-in to one Workspace domain at
		Google, before the browser ever comes back here. It is not a
		substitute for the checks in the callback -- it is a hint Google
		honours, not a guarantee this application can verify -- but it stops
		a personal Google account from even reaching the consent screen.
	*/
	if ('google' === $config['provider'] && '' !== $config['hosted_domain'])
	{
		$params['hd'] = $config['hosted_domain'];
	}
	
	if ('' !== $reauth_scope)
	{
		/*	Record the intent against this session, beside the state and
			nonce written above. callback.php reads it back and refuses to
			act on it unless the subject that returns is the one already
			attached to this session.
		*/
		pl_sso_reauth_store_intent($reauth_scope, $reauth_return);
		
		/*	prompt=login tells the provider to authenticate the user
			afresh instead of replaying its own session. Without it a
			step-up check on a browser that already holds a provider
			session is a silent round trip that proves nothing. Google and
			Entra both honour it, and Entra applies the tenant's MFA and
			conditional-access policy on the re-authentication.
		*/
		$params['prompt'] = 'login';
	}
	
	$separator = (false === strpos($discovery['authorization_endpoint'], '?')) ? '?' : '&';
	$target = $discovery['authorization_endpoint'] . $separator . http_build_query($params);
	
	header('Cache-Control: no-store');
	header('Location: ' . $target);
	exit();
}

catch (plSsoTokenException $e)
{
	pl_sso_bail(503, $e->reason, $e->getMessage());
}

catch (Exception $e)
{
	pl_sso_bail(503, 'login_start_failed', $e->getMessage());
}
