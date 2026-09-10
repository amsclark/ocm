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

/*	A sign-in starts with the browser following a link. Anything else is a
	caller that has confused this endpoint for the callback.
*/
if (isset($_SERVER['REQUEST_METHOD']) && 'GET' !== $_SERVER['REQUEST_METHOD'])
{
	header('HTTP/1.1 405 Method Not Allowed');
	header('Allow: GET');
	header('Content-Type: text/plain; charset=utf-8');
	exit("GET only.\n");
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
