<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

/*	Finish an OpenID Connect sign-in.
	
	The provider sends the browser back here with an authorization code. This
	endpoint turns that code into a session, and every check between the two
	is a check that something else in the flow was not substituted:
	
	  1. state matches the value stored when the redirect was issued, so the
	     code was delivered to the browser that asked for it.
	  2. the handshake rows are deleted before the code is used, so the same
	     code cannot be replayed against a state that is still on file.
	  3. the code is exchanged over a server-to-server POST that carries the
	     PKCE verifier, so a code intercepted in transit is not enough.
	  4. the ID token's signature, issuer, audience, expiry and nonce are all
	     verified before a single claim in it is believed.
	  5. the subject is matched to a local account by pikaAuthSso, which is
	     the only place that mapping is made.
	
	Failures say nothing useful to the browser: one generic message, with the
	specific reason in the audit log. See pikaAuthSso::GENERIC_SSO_FAILURE.
	
	No session and no authorization: the browser arriving here is by
	definition not signed in yet.
*/

chdir('../..');

define('PL_DISABLE_SECURITY', true);

require_once('pika-danio.php');
pika_init();

require_once('pikaSsoOidc.php');
require_once('pikaAuthSso.php');

/*	The code arrives on a redirect, which is a GET. A POST here is either a
	provider configured for form_post -- which this client never asks for --
	or a caller doing something else.
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

// 404, not a message, for the same reason login.php does it.
if (!pl_sso_ready($config, $reason))
{
	pl_sso_bail(404, $reason);
}

/*	The provider's own refusal. This is the ordinary path for a user who
	cancelled at the consent screen, and it is reported before the state check
	because there is no code to protect at this point.
*/
if (isset($_GET['error']) && is_string($_GET['error']) && '' !== $_GET['error'])
{
	$detail = $_GET['error'];
	if (isset($_GET['error_description']) && is_string($_GET['error_description']))
	{
		$detail .= ': ' . $_GET['error_description'];
	}
	
	pl_sso_bail(400, 'provider_error', $detail);
}

$code  = (isset($_GET['code'])  && is_string($_GET['code']))  ? $_GET['code']  : '';
$state = (isset($_GET['state']) && is_string($_GET['state'])) ? $_GET['state'] : '';

if ('' === $code || '' === $state)
{
	pl_sso_bail(400, 'missing_code_or_state');
}

/*	Read the handshake before anything is done with the code, and delete it
	immediately afterwards. Everything from here on uses the three local
	copies; nothing re-reads the table.
*/
$expected_state = pl_sso_state_get('state');
$nonce          = pl_sso_state_get('nonce');
$verifier       = pl_sso_state_get('code_verifier');

pl_sso_state_clear();

/*	No row means no handshake this browser started, or one that started more
	than pl_sso_state_ttl() seconds ago. Either way there is nothing here to
	compare the callback against.
*/
if (false === $expected_state || false === $nonce || false === $verifier)
{
	pl_sso_bail(400, 'no_handshake_state');
}

if (!hash_equals($expected_state, $state))
{
	pl_sso_bail(400, 'state_mismatch');
}

try
{
	$discovery = pl_sso_discovery($config);
	
	$token_response = pl_sso_http_json(
		$discovery['token_endpoint'],
		array(
			'grant_type'    => 'authorization_code',
			'code'          => $code,
			'redirect_uri'  => pl_sso_redirect_uri(),
			'client_id'     => $config['client_id'],
			'client_secret' => $config['client_secret'],
			'code_verifier' => $verifier
		),
		$config
	);
	
	/*	The token endpoint answers 400 with a JSON error object rather than a
		transport failure, so a refusal arrives here as a normal response.
	*/
	if (isset($token_response['error']))
	{
		$detail = (string) $token_response['error'];
		if (isset($token_response['error_description']))
		{
			$detail .= ': ' . (string) $token_response['error_description'];
		}
		
		pl_sso_bail(403, 'token_endpoint_refused', $detail);
	}
	
	if (!isset($token_response['id_token']) || !is_string($token_response['id_token']))
	{
		pl_sso_bail(502, 'no_id_token');
	}
	
	$claims = pl_sso_validate_id_token($token_response['id_token'], $config, $discovery, $nonce);
}

catch (plSsoTokenException $e)
{
	pl_sso_bail(403, $e->reason, $e->getMessage());
}

catch (Exception $e)
{
	/*	DB::preparedQuery() throws a plain Exception under the legacy mysql
		driver, and so does anything else in the chain that fails in a way
		this code did not anticipate. A sign-in that cannot be completed is a
		refused sign-in, not a stack trace on an unauthenticated page.
	*/
	pl_sso_bail(503, 'callback_failed', $e->getMessage());
}

/*	The identity is proven. Whether it belongs to an account here is
	pikaAuthSso's question, and pikaAuth does the session work.
*/
$adapter = new pikaAuthSso($claims, $config);
$auth = pikaAuth::getInstance();

try
{
	$authorized = $auth->authenticate(null, null, $adapter, null);
}

catch (Exception $e)
{
	pl_sso_bail(503, 'session_start_failed', $e->getMessage());
}

if (!$authorized)
{
	/*	pikaAuthSso has already audited the specific reason. A second row
		here would only say "it failed" twice, so this one does not audit --
		but the generic message the adapter set is what the browser sees.
	*/
	$messages = $auth->getMessages();
	$shown = pikaAuthSso::GENERIC_SSO_FAILURE;
	
	foreach ($messages as $message)
	{
		if (isset($message[1]) && is_string($message[1]) && '' !== $message[1])
		{
			$shown = $message[1];
			break;
		}
	}
	
	pl_sso_bail(403, 'not_authorized', '', null, false);
}

/*	Land on the application root rather than on a target taken from the
	request. A returnTo parameter carried through an SSO handshake is an open
	redirect with extra steps, and the 2019 feature set has no page that needs
	one.
*/
$origin = pl_canonical_origin();
$base   = rtrim((string) pl_settings_get('base_url'), '/');

header('Cache-Control: no-store');
header('Location: ' . $origin . $base . '/');
exit();
