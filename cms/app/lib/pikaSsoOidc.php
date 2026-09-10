<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

/*	OpenID Connect, hand-rolled.
	
	This application carries no composer autoloader and no vendor directory,
	so the usual OIDC client libraries are not available to it. What follows
	is the authorization-code flow written out: discovery, state, nonce,
	PKCE, the code-for-token exchange, and RS256 verification of the returned
	ID token against the provider's published keys.
	
	Writing a token verifier by hand is worth being nervous about, so the
	rules it follows are stated once, here, and each is enforced in
	pl_sso_validate_id_token():
	
	  * The signing algorithm is read from an allowlist of exactly one entry,
	    RS256. A token header is attacker-controlled input. A verifier that
	    dispatches on whatever it says there accepts alg=none, and accepts
	    HS256 signed with the public key the provider publishes, and both of
	    those forge any claim set you like.
	  * The signing key is chosen by the header's kid, but only from the set
	    the provider publishes at its jwks_uri, fetched over TLS from a URL
	    the discovery document gave us.
	  * The issuer must equal the configured issuer exactly.
	  * The audience must equal the configured client id exactly.
	  * exp and nbf are checked with sixty seconds of leeway for clock skew,
	    and no more.
	  * The nonce must equal the one this deployment generated for this
	    handshake, which is why it is stored server-side rather than round-
	    tripped through the browser.
	
	Every comparison of a secret or an identifier uses hash_equals().
	
	Nothing here fails open. A fetch that does not answer, a claim that does
	not match, an algorithm that is not RS256: all of them throw
	plSsoTokenException and the caller refuses the sign-in.
*/

require_once(dirname(__FILE__) . '/DB.php');


if (!class_exists('plSsoTokenException'))
{
	/**
	 * Carries a short machine-readable reason alongside the message, so the
	 * audit log records why a sign-in was refused without the message being
	 * shown to the person trying to sign in.
	 */
	class plSsoTokenException extends Exception
	{
		public $reason;
		
		public function __construct($reason, $message = '')
		{
			$this->reason = (string) $reason;
			parent::__construct('' !== $message ? $message : (string) $reason);
		}
	}
}


if (!function_exists('pl_sso_schema_ready'))
{
	/**
	 * Whether add_sso.sql has been applied.
	 *
	 * Memoised for the request and fails closed: any error means "no SSO",
	 * which is the safe answer everywhere this is called. A deployment that
	 * has not run the migration must keep working, not break.
	 *
	 * @return bool
	 */
	function pl_sso_schema_ready()
	{
		static $ready = null;
		
		if (null !== $ready)
		{
			return $ready;
		}
		
		$ready = false;
		
		try
		{
			$columns = DB::query("SHOW COLUMNS FROM `users` LIKE 'sso_subject'");
			
			if (!$columns || DBResult::numRows($columns) < 1)
			{
				return $ready;
			}
			
			$table = DB::query("SHOW TABLES LIKE 'pika_sso_oidc_state'");
			
			if (!$table || DBResult::numRows($table) < 1)
			{
				return $ready;
			}
			
			$ready = true;
		}
		
		catch (Exception $e)
		{
			$ready = false;
		}
		
		return $ready;
	}
}


if (!function_exists('pl_sso_config'))
{
	/**
	 * The SSO configuration, normalised, with the issuer and discovery URL
	 * worked out from the provider.
	 *
	 * @return array
	 */
	function pl_sso_config()
	{
		$provider = strtolower(trim((string) pl_settings_get('sso_provider')));
		$tenant   = trim((string) pl_settings_get('sso_tenant_id'));
		
		$config = array(
			'enabled'           => ('1' === (string) pl_settings_get('sso_enabled')),
			'provider'          => $provider,
			'tenant_id'         => $tenant,
			'hosted_domain'     => trim((string) pl_settings_get('sso_hosted_domain')),
			'client_id'         => trim((string) pl_settings_get('sso_client_id')),
			'client_secret'     => (string) pl_settings_get('sso_client_secret'),
			'autobind'          => ('1' === (string) pl_settings_get('sso_autobind_by_email')),
			'autobind_domains'  => pl_sso_domain_list(pl_settings_get('sso_autobind_domains')),
			'allow_insecure'    => ('1' === (string) pl_settings_get('sso_allow_insecure_transport')),
			'issuer'            => '',
			'discovery_url'     => '',
		);
		
		if ('google' === $provider)
		{
			$config['issuer'] = 'https://accounts.google.com';
		}
		
		elseif ('entra' === $provider)
		{
			/*	The v2.0 issuer. The v1.0 endpoint issues tokens whose iss is
				https://sts.windows.net/<tenant>/ and whose claim shapes
				differ; pinning the version here means the verifier never has
				to guess which it is looking at.
			*/
			if ('' !== $tenant)
			{
				$config['issuer'] = 'https://login.microsoftonline.com/' . $tenant . '/v2.0';
			}
		}
		
		elseif ('generic' === $provider)
		{
			$config['issuer'] = rtrim(trim((string) pl_settings_get('sso_issuer_url')), '/');
		}
		
		$override = trim((string) pl_settings_get('sso_discovery_url'));
		
		if ('' !== $override)
		{
			$config['discovery_url'] = $override;
		}
		
		elseif ('' !== $config['issuer'])
		{
			$config['discovery_url'] = $config['issuer'] . '/.well-known/openid-configuration';
		}
		
		return $config;
	}
}


if (!function_exists('pl_sso_domain_list'))
{
	/**
	 * Split a comma-separated domain allowlist into lowercase entries.
	 *
	 * @param string|null $raw
	 * @return array
	 */
	function pl_sso_domain_list($raw)
	{
		$out = array();
		
		foreach (explode(',', (string) $raw) as $piece)
		{
			$piece = strtolower(trim($piece));
			$piece = ltrim($piece, '@');
			
			if ('' !== $piece)
			{
				$out[] = $piece;
			}
		}
		
		return $out;
	}
}


if (!function_exists('pl_sso_ready'))
{
	/**
	 * Whether an SSO sign-in can be attempted at all: the migration is
	 * applied, the switch is on, and the provider is configured with
	 * everything that provider needs.
	 *
	 * Returns the reason it is not ready in $reason, for the audit log.
	 *
	 * @param array|null $config
	 * @param string     $reason
	 * @return bool
	 */
	function pl_sso_ready($config = null, &$reason = '')
	{
		$reason = '';
		
		if (!pl_sso_schema_ready())
		{
			$reason = 'sso_schema_missing';
			
			return false;
		}
		
		if (!is_array($config))
		{
			$config = pl_sso_config();
		}
		
		if (!$config['enabled'])
		{
			$reason = 'sso_disabled';
			
			return false;
		}
		
		if (!in_array($config['provider'], array('google','entra','generic'), true))
		{
			$reason = 'bad_provider';
			
			return false;
		}
		
		if ('entra' === $config['provider'] && '' === $config['tenant_id'])
		{
			$reason = 'missing_tenant_id';
			
			return false;
		}
		
		if ('' === $config['issuer'] || '' === $config['discovery_url'])
		{
			$reason = 'missing_issuer';
			
			return false;
		}
		
		if ('' === $config['client_id'] || '' === $config['client_secret'])
		{
			$reason = 'missing_client_credentials';
			
			return false;
		}
		
		if (!pl_sso_url_transport_ok($config['issuer'], $config)
				|| !pl_sso_url_transport_ok($config['discovery_url'], $config))
		{
			$reason = 'insecure_issuer';
			
			return false;
		}
		
		return true;
	}
}


if (!function_exists('pl_sso_url_transport_ok'))
{
	/**
	 * True when $url is https, or is http and this deployment has explicitly
	 * allowed that.
	 *
	 * The whole flow's security rests on the transport: the code exchange
	 * carries the client secret, and the JWKS fetch decides which key is
	 * trusted to have signed the token. Over plain http both are readable
	 * and both are rewritable by anything on the path. The escape hatch
	 * exists so an automated test can stand up a local provider, and has no
	 * field on any administration screen for that reason.
	 *
	 * @param string     $url
	 * @param array|null $config
	 * @return bool
	 */
	function pl_sso_url_transport_ok($url, $config = null)
	{
		$scheme = strtolower((string) parse_url((string) $url, PHP_URL_SCHEME));
		
		if ('https' === $scheme)
		{
			return true;
		}
		
		if ('http' !== $scheme)
		{
			return false;
		}
		
		if (!is_array($config))
		{
			$config = pl_sso_config();
		}
		
		return !empty($config['allow_insecure']);
	}
}


if (!function_exists('pl_sso_redirect_uri'))
{
	/**
	 * The callback URL registered at the identity provider.
	 *
	 * Built from the canonical origin rather than from the Host header
	 * wherever the canonical_url setting is set, because the redirect URI is
	 * compared byte for byte by the provider and because a Host header an
	 * attacker chose has no business deciding where a code is delivered.
	 *
	 * @return string
	 */
	function pl_sso_redirect_uri()
	{
		$origin = pl_canonical_origin();
		$base   = rtrim((string) pl_settings_get('base_url'), '/');
		
		return $origin . $base . '/services/sso/callback.php';
	}
}


/* ------------------------------------------------------------------ */
/* Handshake state                                                     */
/* ------------------------------------------------------------------ */

if (!function_exists('pl_sso_state_ttl'))
{
	/**
	 * How long a half-finished handshake stays valid, in seconds.
	 *
	 * @return int
	 */
	function pl_sso_state_ttl()
	{
		return 600;
	}
}


if (!function_exists('pl_sso_state_session_id'))
{
	/**
	 * The key handshake rows are stored under.
	 *
	 * @return string
	 */
	function pl_sso_state_session_id()
	{
		$sid = session_id();
		
		return (is_string($sid) && strlen($sid) > 0) ? $sid : 'no_session';
	}
}


if (!function_exists('pl_sso_state_put'))
{
	/**
	 * Store one handshake value, replacing any previous value for the same
	 * key and session, and prune anything left over from an abandoned flow.
	 *
	 * @param string $key
	 * @param string $value
	 * @return void
	 */
	function pl_sso_state_put($key, $value)
	{
		DB::preparedQuery(
			'INSERT INTO pika_sso_oidc_state (session_id, state_key, state_value)
				VALUES (?, ?, ?)
				ON DUPLICATE KEY UPDATE state_value = VALUES(state_value),
					created_at = CURRENT_TIMESTAMP',
			array(pl_sso_state_session_id(), (string) $key, (string) $value)
		);
		
		DB::preparedQuery(
			'DELETE FROM pika_sso_oidc_state WHERE created_at < (NOW() - INTERVAL ? SECOND)',
			array(pl_sso_state_ttl())
		);
	}
}


if (!function_exists('pl_sso_state_get'))
{
	/**
	 * Read one handshake value, or false when it is absent or expired.
	 *
	 * The age is checked in SQL rather than trusted from the prune above: a
	 * flow whose row survived a failed prune must still time out.
	 *
	 * @param string $key
	 * @return string|false
	 */
	function pl_sso_state_get($key)
	{
		$result = DB::preparedQuery(
			'SELECT state_value FROM pika_sso_oidc_state
				WHERE session_id = ? AND state_key = ?
				AND created_at >= (NOW() - INTERVAL ? SECOND) LIMIT 1',
			array(pl_sso_state_session_id(), (string) $key, pl_sso_state_ttl())
		);
		
		if (!$result || DBResult::numRows($result) != 1)
		{
			return false;
		}
		
		$row = DBResult::fetchRow($result);
		
		return is_array($row) ? (string) $row['state_value'] : false;
	}
}


if (!function_exists('pl_sso_state_clear'))
{
	/**
	 * Drop every handshake row for this session. Called once the callback
	 * has read what it needs, whether or not the sign-in succeeded, so a
	 * code cannot be replayed against a state that is still on file.
	 *
	 * @return void
	 */
	function pl_sso_state_clear()
	{
		DB::preparedQuery(
			'DELETE FROM pika_sso_oidc_state WHERE session_id = ?',
			array(pl_sso_state_session_id())
		);
	}
}


/* ------------------------------------------------------------------ */
/* Encoding helpers                                                    */
/* ------------------------------------------------------------------ */

if (!function_exists('pl_sso_base64url_encode'))
{
	/**
	 * @param string $value
	 * @return string
	 */
	function pl_sso_base64url_encode($value)
	{
		return rtrim(strtr(base64_encode((string) $value), '+/', '-_'), '=');
	}
}


if (!function_exists('pl_sso_base64url_decode'))
{
	/**
	 * Strict base64url decode. Refuses any character outside the alphabet
	 * rather than silently dropping it, because a decoder that ignores
	 * rubbish lets two different strings decode to the same bytes.
	 *
	 * @param string $value
	 * @return string|false
	 */
	function pl_sso_base64url_decode($value)
	{
		$value = (string) $value;
		
		if ('' === $value || preg_match('/[^A-Za-z0-9_-]/', $value))
		{
			return false;
		}
		
		$padding = strlen($value) % 4;
		
		if ($padding > 0)
		{
			$value .= str_repeat('=', 4 - $padding);
		}
		
		return base64_decode(strtr($value, '-_', '+/'), true);
	}
}


if (!function_exists('pl_sso_der_length'))
{
	/**
	 * DER length prefix for $length bytes.
	 *
	 * @param int $length
	 * @return string
	 */
	function pl_sso_der_length($length)
	{
		$length = (int) $length;
		
		if ($length < 128)
		{
			return chr($length);
		}
		
		$encoded = '';
		
		while ($length > 0)
		{
			$encoded = chr($length & 0xff) . $encoded;
			$length >>= 8;
		}
		
		return chr(0x80 | strlen($encoded)) . $encoded;
	}
}


if (!function_exists('pl_sso_der_integer'))
{
	/**
	 * DER INTEGER holding $bytes, big-endian, with the sign bit cleared.
	 *
	 * @param string $bytes
	 * @return string
	 */
	function pl_sso_der_integer($bytes)
	{
		$bytes = ltrim((string) $bytes, "\x00");
		
		if ('' === $bytes)
		{
			$bytes = "\x00";
		}
		
		elseif (0 !== (ord($bytes[0]) & 0x80))
		{
			$bytes = "\x00" . $bytes;
		}
		
		return "\x02" . pl_sso_der_length(strlen($bytes)) . $bytes;
	}
}


if (!function_exists('pl_sso_jwk_to_pem'))
{
	/**
	 * Turn one RSA JWK into a PEM public key.
	 *
	 * openssl_verify() needs a key, and PHP has no way to build one from a
	 * raw modulus and exponent, so the SubjectPublicKeyInfo structure is
	 * assembled by hand: an RSAPublicKey SEQUENCE of two INTEGERs, wrapped
	 * in a BIT STRING, after the rsaEncryption algorithm identifier.
	 *
	 * Returns null for anything that is not an RSA key. An EC key from a
	 * provider we do not support has to be refused rather than guessed at.
	 *
	 * @param array $jwk
	 * @return string|null
	 */
	function pl_sso_jwk_to_pem(array $jwk)
	{
		$kty = isset($jwk['kty']) ? (string) $jwk['kty'] : '';
		
		if ('RSA' !== $kty || empty($jwk['n']) || empty($jwk['e']))
		{
			return null;
		}
		
		$modulus  = pl_sso_base64url_decode($jwk['n']);
		$exponent = pl_sso_base64url_decode($jwk['e']);
		
		if (false === $modulus || false === $exponent)
		{
			return null;
		}
		
		$rsa = pl_sso_der_integer($modulus) . pl_sso_der_integer($exponent);
		$rsa = "\x30" . pl_sso_der_length(strlen($rsa)) . $rsa;
		
		// OBJECT IDENTIFIER 1.2.840.113549.1.1.1 (rsaEncryption), NULL params.
		$algorithm  = "\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00";
		$bit_string = "\x03" . pl_sso_der_length(strlen($rsa) + 1) . "\x00" . $rsa;
		$spki       = $algorithm . $bit_string;
		$spki       = "\x30" . pl_sso_der_length(strlen($spki)) . $spki;
		
		return "-----BEGIN PUBLIC KEY-----\n"
			. chunk_split(base64_encode($spki), 64, "\n")
			. "-----END PUBLIC KEY-----\n";
	}
}


/* ------------------------------------------------------------------ */
/* HTTP                                                                */
/* ------------------------------------------------------------------ */

if (!function_exists('pl_sso_http'))
{
	/**
	 * One HTTP request to the identity provider. GET when $post is null,
	 * otherwise an application/x-www-form-urlencoded POST.
	 *
	 * Redirects are never followed. A provider endpoint that answers 302 is
	 * either misconfigured or is being redirected somewhere else by
	 * something on the path, and following it would send the client secret,
	 * or accept a key set, from wherever it pointed.
	 *
	 * @param string     $url
	 * @param array|null $post
	 * @param array|null $config
	 * @return string the response body
	 * @throws plSsoTokenException
	 */
	function pl_sso_http($url, $post = null, $config = null)
	{
		$url = (string) $url;
		
		if (!pl_sso_url_transport_ok($url, $config))
		{
			throw new plSsoTokenException('insecure_endpoint', $url);
		}
		
		$body = is_array($post) ? http_build_query($post) : null;
		
		if (function_exists('curl_init'))
		{
			$ch = curl_init($url);
			curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
			curl_setopt($ch, CURLOPT_FOLLOWLOCATION, false);
			curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 5);
			curl_setopt($ch, CURLOPT_TIMEOUT, 10);
			curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);
			curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, 2);
			
			if (null !== $body)
			{
				curl_setopt($ch, CURLOPT_POST, true);
				curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
				curl_setopt($ch, CURLOPT_HTTPHEADER, array(
					'Content-Type: application/x-www-form-urlencoded',
					'Accept: application/json'
				));
			}
			
			else
			{
				curl_setopt($ch, CURLOPT_HTTPHEADER, array('Accept: application/json'));
			}
			
			$response = curl_exec($ch);
			$status   = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
			$error    = curl_error($ch);
			curl_close($ch);
			
			if (false === $response)
			{
				throw new plSsoTokenException('http_failed', $url . ': ' . $error);
			}
			
			/*	The token endpoint answers 400 with a JSON error object that
				says what went wrong, and that is worth reading, so the body
				comes back for any status. The caller decides.
			*/
			if ($status < 200 || $status >= 500)
			{
				throw new plSsoTokenException('http_status', $url . ': ' . $status);
			}
			
			return (string) $response;
		}
		
		$options = array(
			'http' => array(
				'timeout'         => 10,
				'ignore_errors'   => true,
				'follow_location' => 0,
				'header'          => "Accept: application/json\r\n"
			)
		);
		
		if (null !== $body)
		{
			$options['http']['method']  = 'POST';
			$options['http']['header'] .= "Content-Type: application/x-www-form-urlencoded\r\n";
			$options['http']['content'] = $body;
		}
		
		$response = @file_get_contents($url, false, stream_context_create($options));
		
		if (!is_string($response))
		{
			throw new plSsoTokenException('http_failed', $url);
		}
		
		return $response;
	}
}


if (!function_exists('pl_sso_http_json'))
{
	/**
	 * pl_sso_http() with a JSON object expected back.
	 *
	 * @param string     $url
	 * @param array|null $post
	 * @param array|null $config
	 * @return array
	 * @throws plSsoTokenException
	 */
	function pl_sso_http_json($url, $post = null, $config = null)
	{
		$decoded = json_decode(pl_sso_http($url, $post, $config), true);
		
		if (!is_array($decoded))
		{
			throw new plSsoTokenException('bad_json', $url);
		}
		
		return $decoded;
	}
}


if (!function_exists('pl_sso_discovery'))
{
	/**
	 * The provider's discovery document, with the endpoints this flow uses
	 * present and the issuer confirmed to be the configured one.
	 *
	 * Checking the issuer here as well as on the token is what stops a
	 * discovery URL that was mistyped, or repointed, from quietly moving the
	 * whole flow to another provider: every endpoint used afterwards comes
	 * out of this document.
	 *
	 * @param array $config
	 * @return array
	 * @throws plSsoTokenException
	 */
	function pl_sso_discovery(array $config)
	{
		static $cache = array();
		
		$key = $config['discovery_url'];
		
		if (isset($cache[$key]))
		{
			return $cache[$key];
		}
		
		$doc = pl_sso_http_json($config['discovery_url'], null, $config);
		
		foreach (array('issuer','authorization_endpoint','token_endpoint','jwks_uri') as $field)
		{
			if (empty($doc[$field]) || !is_string($doc[$field]))
			{
				throw new plSsoTokenException('discovery_incomplete', $field);
			}
		}
		
		if (!hash_equals($config['issuer'], (string) $doc['issuer']))
		{
			throw new plSsoTokenException('discovery_issuer_mismatch',
				$doc['issuer'] . ' != ' . $config['issuer']);
		}
		
		foreach (array('authorization_endpoint','token_endpoint','jwks_uri') as $field)
		{
			if (!pl_sso_url_transport_ok($doc[$field], $config))
			{
				throw new plSsoTokenException('insecure_endpoint', $field);
			}
		}
		
		$cache[$key] = $doc;
		
		return $doc;
	}
}


if (!function_exists('pl_sso_jwks'))
{
	/**
	 * The provider's signing keys.
	 *
	 * Fetched per request. There is no cache on disk or in the settings
	 * table: sign-ins are human-paced, one extra request against the
	 * provider costs a few hundred milliseconds, and a cache of the material
	 * that decides which signature is trusted is a thing that has to be
	 * invalidated correctly every time or it becomes the bug.
	 *
	 * @param array $config
	 * @param array $discovery
	 * @return array list of JWKs
	 * @throws plSsoTokenException
	 */
	function pl_sso_jwks(array $config, array $discovery)
	{
		static $cache = array();
		
		$uri = (string) $discovery['jwks_uri'];
		
		if (isset($cache[$uri]))
		{
			return $cache[$uri];
		}
		
		$doc = pl_sso_http_json($uri, null, $config);
		
		if (!isset($doc['keys']) || !is_array($doc['keys']) || 0 === count($doc['keys']))
		{
			throw new plSsoTokenException('jwks_unavailable', $uri);
		}
		
		$cache[$uri] = $doc['keys'];
		
		return $doc['keys'];
	}
}


/* ------------------------------------------------------------------ */
/* Token verification                                                  */
/* ------------------------------------------------------------------ */

if (!function_exists('pl_sso_validate_id_token'))
{
	/**
	 * Verify an ID token and return its claims.
	 *
	 * @param string $token     the compact JWS from the token endpoint
	 * @param array  $config
	 * @param array  $discovery
	 * @param string $nonce     the nonce this deployment generated
	 * @return array the verified claims
	 * @throws plSsoTokenException
	 */
	function pl_sso_validate_id_token($token, array $config, array $discovery, $nonce)
	{
		$parts = explode('.', (string) $token);
		
		if (3 !== count($parts))
		{
			throw new plSsoTokenException('malformed_token');
		}
		
		$header_raw = pl_sso_base64url_decode($parts[0]);
		$claims_raw = pl_sso_base64url_decode($parts[1]);
		$signature  = pl_sso_base64url_decode($parts[2]);
		$header     = is_string($header_raw) ? json_decode($header_raw, true) : null;
		$claims     = is_string($claims_raw) ? json_decode($claims_raw, true) : null;
		
		if (!is_array($header) || !is_array($claims) || false === $signature)
		{
			throw new plSsoTokenException('malformed_token');
		}
		
		/*	One algorithm, compared as a constant. Not a lookup table, not a
			default: an allowlist of length one.
		*/
		if (!isset($header['alg']) || !hash_equals('RS256', (string) $header['alg']))
		{
			throw new plSsoTokenException('bad_algorithm');
		}
		
		$kid = isset($header['kid']) ? (string) $header['kid'] : '';
		$key = null;
		
		foreach (pl_sso_jwks($config, $discovery) as $candidate)
		{
			if (!is_array($candidate))
			{
				continue;
			}
			
			$candidate_kid = isset($candidate['kid']) ? (string) $candidate['kid'] : '';
			
			/*	A key set with exactly one key and no kid at all is legal, and
				some self-hosted providers publish that, so an empty kid on
				both sides matches. An empty kid on the token against a key
				set that does name its keys does not.
			*/
			if (hash_equals($candidate_kid, $kid))
			{
				$key = $candidate;
				
				break;
			}
		}
		
		if (null === $key)
		{
			throw new plSsoTokenException('unknown_signing_key', $kid);
		}
		
		$use = isset($key['use']) ? (string) $key['use'] : 'sig';
		
		if ('sig' !== $use)
		{
			throw new plSsoTokenException('key_not_for_signing', $use);
		}
		
		$pem        = pl_sso_jwk_to_pem($key);
		$public_key = is_string($pem) ? openssl_pkey_get_public($pem) : false;
		
		if (false === $public_key)
		{
			throw new plSsoTokenException('bad_signing_key');
		}
		
		$verified = openssl_verify(
			$parts[0] . '.' . $parts[1],
			$signature,
			$public_key,
			OPENSSL_ALGO_SHA256
		);
		
		if (1 !== $verified)
		{
			throw new plSsoTokenException('bad_signature');
		}
		
		// Claims, in the order that makes a failure easiest to read.
		$issuer = isset($claims['iss']) ? (string) $claims['iss'] : '';
		
		if (!hash_equals($config['issuer'], $issuer))
		{
			throw new plSsoTokenException('bad_issuer', $issuer);
		}
		
		/*	aud may be a string or a list. Either way the configured client
			id has to be in it, and nothing else is accepted -- a token minted
			for another application at the same provider is not a sign-in
			here.
		*/
		$audience = isset($claims['aud']) ? $claims['aud'] : '';
		$audience = is_array($audience) ? $audience : array($audience);
		$aud_ok   = false;
		
		foreach ($audience as $one)
		{
			if (is_string($one) && hash_equals($config['client_id'], $one))
			{
				$aud_ok = true;
				
				break;
			}
		}
		
		if (!$aud_ok)
		{
			throw new plSsoTokenException('bad_audience');
		}
		
		/*	azp identifies which client the token was actually issued to when
			aud carries more than one value. If it is present it has to be us.
		*/
		if (isset($claims['azp']) && is_string($claims['azp'])
				&& !hash_equals($config['client_id'], $claims['azp']))
		{
			throw new plSsoTokenException('bad_authorized_party');
		}
		
		$now    = time();
		$leeway = 60;
		
		if (!isset($claims['exp']) || !is_numeric($claims['exp']))
		{
			throw new plSsoTokenException('missing_expiry');
		}
		
		if ((int) $claims['exp'] + $leeway < $now)
		{
			throw new plSsoTokenException('expired_token');
		}
		
		if (isset($claims['nbf']) && is_numeric($claims['nbf'])
				&& (int) $claims['nbf'] - $leeway > $now)
		{
			throw new plSsoTokenException('token_not_yet_valid');
		}
		
		if (isset($claims['iat']) && is_numeric($claims['iat'])
				&& (int) $claims['iat'] - $leeway > $now)
		{
			throw new plSsoTokenException('token_issued_in_future');
		}
		
		/*	The nonce ties this token to the redirect this deployment sent.
			Without it a token the provider issued for another sign-in of the
			same user at the same client -- captured anywhere, replayed here
			-- is accepted.
		*/
		$token_nonce = isset($claims['nonce']) ? (string) $claims['nonce'] : '';
		
		if ('' === (string) $nonce || !hash_equals((string) $nonce, $token_nonce))
		{
			throw new plSsoTokenException('bad_nonce');
		}
		
		if (empty($claims['sub']) || !is_string($claims['sub']))
		{
			throw new plSsoTokenException('missing_sub_claim');
		}
		
		return $claims;
	}
}


if (!function_exists('pl_sso_verified_email'))
{
	/**
	 * The email address the provider vouches for, lowercased, or '' when it
	 * vouches for none.
	 *
	 * Google publishes email_verified and it has to be true. Entra does not
	 * emit that claim for managed tenant accounts at all, so for a token
	 * that has already passed signature and tenant checks a non-empty
	 * address counts as verified -- the directory is the authority on its own
	 * users' addresses. preferred_username and upn are the fallbacks for an
	 * app registration that does not release the email claim.
	 *
	 * @param array $claims
	 * @param array $config
	 * @return string
	 */
	function pl_sso_verified_email(array $claims, array $config)
	{
		$email = '';
		
		foreach (array('email','preferred_username','upn') as $field)
		{
			if (!empty($claims[$field]) && is_string($claims[$field])
					&& false !== strpos($claims[$field], '@'))
			{
				$email = strtolower(trim($claims[$field]));
				
				break;
			}
		}
		
		if ('' === $email)
		{
			return '';
		}
		
		if ('google' === $config['provider'])
		{
			$verified = isset($claims['email_verified']) ? $claims['email_verified'] : null;
			
			if (true !== $verified && 'true' !== $verified && 1 !== $verified && '1' !== $verified)
			{
				return '';
			}
		}
		
		return $email;
	}
}


/* ------------------------------------------------------------------ */
/* Users                                                               */
/* ------------------------------------------------------------------ */

if (!function_exists('pl_sso_user_is_sso'))
{
	/**
	 * Whether this account signs in through the identity provider.
	 *
	 * Memoised for the request. Fails closed -- an error, or a database
	 * without the migration, answers "no" -- because the callers use the
	 * answer to waive local credential policy, and waiving it by accident is
	 * worse than applying it to somebody it cannot apply to.
	 *
	 * @param int $user_id
	 * @return bool
	 */
	function pl_sso_user_is_sso($user_id)
	{
		static $cache = array();
		
		$user_id = (int) $user_id;
		
		if ($user_id <= 0)
		{
			return false;
		}
		
		if (isset($cache[$user_id]))
		{
			return $cache[$user_id];
		}
		
		$cache[$user_id] = false;
		
		if (!pl_sso_schema_ready())
		{
			return false;
		}
		
		try
		{
			$result = DB::preparedQuery(
				'SELECT auth_method FROM users WHERE user_id = ? LIMIT 1',
				array($user_id)
			);
			
			if ($result && DBResult::numRows($result) == 1)
			{
				$row = DBResult::fetchRow($result);
				$cache[$user_id] = ('sso' === (string) $row['auth_method']);
			}
		}
		
		catch (Exception $e)
		{
			$cache[$user_id] = false;
		}
		
		return $cache[$user_id];
	}
}



if (!function_exists('pl_sso_session_user'))
{
	/**
	 * The account behind the session cookie on this request.
	 *
	 * cms/services/logout.php and cms/m/logout.php define
	 * PL_DISABLE_SECURITY, so pika_init() never authenticates and $auth_row
	 * is empty there. pikaAuth works around that internally by reading
	 * user_sessions itself, but the session id it uses is private, so a
	 * caller outside the class cannot ask it. This reads the same row the
	 * same way.
	 *
	 * Nothing the request supplied is trusted: the lookup is on the session
	 * id only, and the row must still be live.
	 *
	 * Call it BEFORE pikaAuth::logout(), which sets logout = 1 and makes
	 * this return null.
	 *
	 * @return array|null user_id, username and auth_method, or null
	 */
	function pl_sso_session_user()
	{
		if (session_id() === '')
		{
			return null;
		}
		
		$sid = session_id();
		
		if (isset($_SESSION['SID']) && $_SESSION['SID'])
		{
			$sid = $_SESSION['SID'];
		}
		
		try
		{
			$result = DB::preparedQuery(
				"SELECT users.user_id, users.username, users.auth_method
					FROM user_sessions
					JOIN users ON users.user_id = user_sessions.user_id
					WHERE user_sessions.session_id = ?
						AND (user_sessions.logout IS NULL OR user_sessions.logout = 0)
						AND users.enabled = '1'
					LIMIT 1",
				array($sid)
			);
			
			if (!$result || DBResult::numRows($result) != 1)
			{
				return null;
			}
			
			$row = DBResult::fetchRow($result);
			
			return is_array($row) ? $row : null;
		}
		
		catch (Exception $e)
		{
			/*	An installation that has not run add_sso.sql has no
				auth_method column. Sign-out must still work there.
			*/
			return null;
		}
	}
}


if (!function_exists('pl_sso_end_session_url'))
{
	/**
	 * Where to send the browser after a local sign-out so that the identity
	 * provider's session ends too, or '' to stay local.
	 *
	 * The endpoint is read from the provider's discovery document rather
	 * than hard-coded, so this works for any provider that publishes
	 * end_session_endpoint. Google does not publish one, and its account
	 * sign-out URL would sign the user out of every Google service, so a
	 * Google deployment stays local and that is the intended result.
	 *
	 * post_logout_redirect_uri is built from pl_canonical_origin(), not from
	 * the Host header. The provider compares that value against a registered
	 * list byte for byte, so a forged Host would produce a URI the provider
	 * rejects and an error page instead of a sign-out.
	 *
	 * Fails closed to '' on anything unexpected: an unreachable provider
	 * must not stop somebody signing out.
	 *
	 * @return string absolute URL, or ''
	 */
	function pl_sso_end_session_url()
	{
		try
		{
			if ('1' !== (string) pl_settings_get('sso_single_logout'))
			{
				return '';
			}
			
			$config = pl_sso_config();
			
			if (empty($config['enabled']) || '' === $config['discovery_url'])
			{
				return '';
			}
			
			$discovery = pl_sso_discovery($config);
			
			if (empty($discovery['end_session_endpoint'])
				|| !is_string($discovery['end_session_endpoint']))
			{
				return '';
			}
			
			$endpoint = $discovery['end_session_endpoint'];
			
			/*	pl_sso_discovery() checks the three endpoints the sign-in flow
				uses. This one is not among them, so it is checked here.
			*/
			if (!pl_sso_url_transport_ok($endpoint, $config))
			{
				return '';
			}
			
			$params = array(
				'post_logout_redirect_uri' => pl_canonical_origin()
					. rtrim((string) pl_settings_get('base_url'), '/') . '/'
			);
			
			/*	Entra requires the client id when a post-logout redirect is
				asked for; other providers ignore it.
			*/
			if ('' !== $config['client_id'])
			{
				$params['client_id'] = $config['client_id'];
			}
			
			$separator = (false === strpos($endpoint, '?')) ? '?' : '&';
			
			return $endpoint . $separator . http_build_query($params);
		}
		
		catch (Exception $e)
		{
			error_log('pl_sso_end_session_url staying local: ' . $e->getMessage());
			
			return '';
		}
	}
}

if (!function_exists('pl_sso_login_button_html'))
{
	/**
	 * The "sign in with" control for the login page, or '' when SSO is not
	 * configured.
	 *
	 * Runs before authentication, on a page anybody can reach, so it says
	 * nothing beyond which provider this deployment uses -- which the
	 * redirect would reveal anyway.
	 *
	 * @return string
	 */
	function pl_sso_login_button_html()
	{
		$reason = '';
		
		try
		{
			if (!pl_sso_ready(null, $reason))
			{
				return '';
			}
			
			$config = pl_sso_config();
		}
		
		catch (Exception $e)
		{
			return '';
		}
		
		$names = array(
			'google'  => 'Google',
			'entra'   => 'Microsoft',
			'generic' => 'your organization&rsquo;s identity provider'
		);
		
		$label = isset($names[$config['provider']]) ? $names[$config['provider']] : 'single sign-on';
		$base  = rtrim((string) pl_settings_get('base_url'), '/');
		
		return '<div class="control-group" id="sso_login">'
			. '<div class="controls">'
			. '<a class="btn" href="' . pl_html_escape($base . '/services/sso/login.php') . '">'
			. 'Sign in with ' . $label . '</a>'
			. '</div></div>';
	}
}


if (!function_exists('pl_sso_bail'))
{
	/**
	 * End an SSO request that cannot continue: record why, tell the browser
	 * as little as possible, and stop.
	 *
	 * The reason goes to the audit log and the server error log. The page
	 * says only that the sign-in did not complete, because the two endpoints
	 * this is called from are reachable without a session and every distinct
	 * message they could return is an answer to a question somebody
	 * enumerating the deployment would like answered.
	 *
	 * @param int        $status HTTP status
	 * @param string     $reason short machine-readable reason
	 * @param string     $detail extra text for the error log only
	 * @param array|null $extra  extra audit detail fields
	 * @param bool       $audit  false when the caller has already recorded a
	 *                           more specific reason and a second, vaguer row
	 *                           would only make the log harder to read
	 * @return void does not return
	 */
	function pl_sso_bail($status, $reason, $detail = '', $extra = null, $audit = true)
	{
		$details = is_array($extra) ? $extra : array();
		$details['reason'] = $reason;
		
		if ($audit && function_exists('pl_audit'))
		{
			pl_audit('sso.login.failure', null, null, $details);
		}
		
		error_log('SSO: ' . $reason . ('' !== (string) $detail ? ' (' . $detail . ')' : ''));
		
		$status = (int) $status;
		$titles = array(400 => 'Bad Request', 403 => 'Forbidden', 404 => 'Not Found',
			500 => 'Internal Server Error', 503 => 'Service Unavailable');
		$title = isset($titles[$status]) ? $titles[$status] : 'Error';
		
		if (!headers_sent())
		{
			header('HTTP/1.1 ' . $status . ' ' . $title);
			header('Content-Type: text/plain; charset=utf-8');
			header('Cache-Control: no-store');
		}
		
		$base = rtrim((string) pl_settings_get('base_url'), '/');
		
		echo "Single sign-on did not complete.\n\n"
			. "Return to the sign-in page: " . $base . "/\n\n"
			. "If this keeps happening, ask your administrator to check the audit log.\n";
		
		exit();
	}
}
