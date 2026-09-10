<?php
/*	A fake OpenID Connect provider, for tests/smoke.sh only.
	
	tests/smoke.sh writes this file into the running container, drives the
	whole authorization-code flow through it with curl, and deletes it again.
	It must never be present in a deployment: it signs tokens for whoever
	asks. The name starts with zz_ so it sorts last and reads as a fixture.
	
	Its configuration and its signing keys live in /tmp inside the container,
	written by the test, so nothing about a real provider is needed.
	
	Misbehaviour is requested through a flags file, one word per behaviour,
	so the test can check that the application refuses a bad token rather
	than only that it accepts a good one.
*/

$STATE_DIR = '/tmp/zz_test_idp';
@mkdir($STATE_DIR, 0700, true);

$CONFIG = array();
if (file_exists($STATE_DIR . '/config.json'))
{
	$CONFIG = json_decode(file_get_contents($STATE_DIR . '/config.json'), true);
}
if (!is_array($CONFIG))
{
	$CONFIG = array();
}

/*	The test writes config.json before it uses this file and deletes the file
	afterwards. Without that config there is no test in progress, so answer
	nothing: if a crash ever leaves this fixture behind in a webroot, it must
	not sign anything for whoever finds it.
*/
if (!isset($CONFIG['client_id']) || '' === (string) $CONFIG['client_id'])
{
	header('HTTP/1.1 404 Not Found');
	exit;
}

$FLAGS = file_exists($STATE_DIR . '/flags')
	? trim(file_get_contents($STATE_DIR . '/flags'))
	: '';

function idp_flag($name)
{
	global $FLAGS;
	return (false !== strpos(' ' . $FLAGS . ' ', ' ' . $name . ' '));
}

function idp_cfg($name, $default = '')
{
	global $CONFIG;
	return isset($CONFIG[$name]) ? (string) $CONFIG[$name] : $default;
}

function idp_key($which)
{
	global $STATE_DIR;
	$file = $STATE_DIR . '/' . $which . '.pem';
	
	if (!file_exists($file))
	{
		$res = openssl_pkey_new(array(
			'private_key_bits' => 2048,
			'private_key_type' => OPENSSL_KEYTYPE_RSA
		));
		$pem = '';
		openssl_pkey_export($res, $pem);
		file_put_contents($file, $pem);
		chmod($file, 0600);
	}
	
	return openssl_pkey_get_private(file_get_contents($file));
}

function idp_b64u($value)
{
	return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
}

function idp_json($data, $status = 200)
{
	header('HTTP/1.1 ' . $status);
	header('Content-Type: application/json');
	header('Cache-Control: no-store');
	echo json_encode($data);
	exit();
}

$browser = idp_cfg('browser_base');
$server  = idp_cfg('server_base');
$issuer  = idp_cfg('issuer');
$ep      = isset($_GET['ep']) ? (string) $_GET['ep'] : '';

switch ($ep)
{
	case 'discovery':
		/*	Two different bases on purpose. The browser reaches the
			container through the published port on the host; the container
			reaches itself on port 80. A single base cannot be right for
			both, and a discovery document is exactly where a provider gets
			to say so.
		*/
		$doc = array(
			'issuer'                                => $issuer,
			'authorization_endpoint'                => $browser . '?ep=authorize',
			'token_endpoint'                        => $server . '?ep=token',
			'jwks_uri'                              => $server . '?ep=jwks',
			'response_types_supported'              => array('code'),
			'subject_types_supported'               => array('public'),
			'id_token_signing_alg_values_supported' => array('RS256')
		);
		
		/*	RP-initiated logout. Optional in the specification and absent
			from some real providers, Google among them, so the flag lets a
			test see what the application does without it.
		*/
		if (!idp_flag('no_end_session'))
		{
			$doc['end_session_endpoint'] = $browser . '?ep=endsession';
		}
		
		idp_json($doc);
		break;
	
	case 'endsession':
		/*	A real provider clears its own cookie here and then returns the
			browser to post_logout_redirect_uri. Nothing here holds a
			provider-side session, so saying so is the whole job.
		*/
		header('Content-Type: text/plain; charset=utf-8');
		echo "provider session ended\n";
		echo 'post_logout_redirect_uri='
			. (isset($_GET['post_logout_redirect_uri'])
				? (string) $_GET['post_logout_redirect_uri'] : '') . "\n";
		exit();
	
	case 'jwks':
		$details = openssl_pkey_get_details(idp_key('key'));
		idp_json(array('keys' => array(array(
			'kty' => 'RSA',
			'use' => 'sig',
			'alg' => 'RS256',
			'kid' => 'zzidp1',
			'n'   => idp_b64u($details['rsa']['n']),
			'e'   => idp_b64u($details['rsa']['e'])
		))));
		break;
	
	case 'authorize':
		$redirect = isset($_GET['redirect_uri']) ? (string) $_GET['redirect_uri'] : '';
		
		if ('' === $redirect)
		{
			idp_json(array('error' => 'invalid_request'), 400);
		}
		
		$code = bin2hex(random_bytes(16));
		file_put_contents($STATE_DIR . '/code_' . $code . '.json', json_encode(array(
			'nonce'          => isset($_GET['nonce']) ? (string) $_GET['nonce'] : '',
			'code_challenge' => isset($_GET['code_challenge']) ? (string) $_GET['code_challenge'] : '',
			'redirect_uri'   => $redirect
		)));
		
		$state = isset($_GET['state']) ? (string) $_GET['state'] : '';
		
		if (idp_flag('badstate'))
		{
			$state = 'zz-not-the-state-that-was-sent';
		}
		
		$separator = (false === strpos($redirect, '?')) ? '?' : '&';
		header('HTTP/1.1 302 Found');
		header('Location: ' . $redirect . $separator
			. http_build_query(array('code' => $code, 'state' => $state)));
		exit();
		break;
	
	case 'token':
		$code = isset($_POST['code']) ? (string) $_POST['code'] : '';
		$file = $STATE_DIR . '/code_' . preg_replace('/[^0-9a-f]/', '', $code) . '.json';
		
		if ('' === $code || !file_exists($file))
		{
			idp_json(array('error' => 'invalid_grant'), 400);
		}
		
		$saved = json_decode(file_get_contents($file), true);
		unlink($file);
		
		if (!is_array($saved))
		{
			idp_json(array('error' => 'invalid_grant'), 400);
		}
		
		// The client secret is what the provider knows the client by.
		if ((string) idp_cfg('client_secret') !== (isset($_POST['client_secret']) ? (string) $_POST['client_secret'] : ''))
		{
			idp_json(array('error' => 'invalid_client'), 401);
		}
		
		/*	PKCE, checked for real. A test provider that accepted any
			verifier would let the application pass this section with the
			verifier left out entirely.
		*/
		$verifier = isset($_POST['code_verifier']) ? (string) $_POST['code_verifier'] : '';
		if (idp_b64u(hash('sha256', $verifier, true)) !== (string) $saved['code_challenge'])
		{
			idp_json(array('error' => 'invalid_grant', 'error_description' => 'bad code_verifier'), 400);
		}
		
		$now = time();
		$nonce = (string) $saved['nonce'];
		
		if (idp_flag('badnonce'))
		{
			$nonce = 'zz-not-the-nonce-that-was-sent';
		}
		
		$claims = array(
			'iss'            => idp_flag('badissuer') ? 'https://zz-not-the-issuer.example' : $issuer,
			'aud'            => idp_flag('badaudience') ? 'zz-not-this-client' : idp_cfg('client_id'),
			'sub'            => idp_cfg('sub'),
			'email'          => idp_cfg('email'),
			'email_verified' => true,
			'nonce'          => $nonce,
			'iat'            => $now,
			'nbf'            => $now - 5,
			'exp'            => idp_flag('expired') ? ($now - 3600) : ($now + 300)
		);
		
		if (idp_flag('nosub'))
		{
			unset($claims['sub']);
		}
		
		$header = array(
			'typ' => 'JWT',
			'alg' => idp_flag('badalg') ? 'HS256' : 'RS256',
			'kid' => idp_flag('badkid') ? 'zz-unknown-kid' : 'zzidp1'
		);
		
		$signing_input = idp_b64u(json_encode($header)) . '.' . idp_b64u(json_encode($claims));
		
		// key2 is never published in the JWKS, so a token signed with it has
		// a well-formed signature that does not verify.
		$signature = '';
		openssl_sign(
			$signing_input,
			$signature,
			idp_key(idp_flag('wrongkey') ? 'key2' : 'key'),
			OPENSSL_ALGO_SHA256
		);
		
		idp_json(array(
			'token_type'   => 'Bearer',
			'access_token' => bin2hex(random_bytes(16)),
			'expires_in'   => 300,
			'id_token'     => $signing_input . '.' . idp_b64u($signature)
		));
		break;
	
	default:
		idp_json(array('error' => 'unknown_endpoint'), 404);
}
