<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

/*	Step-up re-authentication for accounts that sign in through an
	identity provider.
	
	pl_reauth_required() puts the most sensitive changes -- system
	settings, user administration, a password change -- behind a fresh
	check of the current password. An SSO account has no local password
	to check, because linking one clears it on purpose, so without a
	second route those users would be refused every gated action with no
	error they could act on.
	
	The second route is a fresh trip to the identity provider:
	
	  1. pl_reauth_required() draws the SSO challenge page, which POSTs a
	     scope and a return path to services/sso/login.php.
	  2. login.php checks the CSRF token, the live session and the scope,
	     stores the intent here, and adds prompt=login to the request it
	     sends to the provider.
	  3. The provider re-authenticates the user under whatever policy the
	     tenant enforces.
	  4. callback.php reads the intent back, checks the subject that came
	     back against the subject already bound to the session's user,
	     writes the reauth_grants row, and returns the browser to the
	     page the user started from.
	
	The intent is stored in pika_sso_oidc_state, the same table the
	handshake uses, because this application's session save handler is a
	no-op by design and $_SESSION does not survive the redirect. Rows
	there are pruned at pl_sso_state_ttl() seconds, which outlasts a
	round trip and bounds an abandoned one.
*/

/** The state_key that holds the scope half of a stored intent. */
if (!defined('PL_SSO_REAUTH_KEY_SCOPE'))
{
	define('PL_SSO_REAUTH_KEY_SCOPE', 'pika_reauth_scope');
}

/** The state_key that holds the return-path half of a stored intent. */
if (!defined('PL_SSO_REAUTH_KEY_RETURN'))
{
	define('PL_SSO_REAUTH_KEY_RETURN', 'pika_reauth_return');
}


if (!function_exists('pl_sso_reauth_session_id'))
{
	/**
	 * @return string|null
	 * @desc The session id an intent and its grant are keyed on. It is
	 * the same value pl_sso_state_session_id() uses for the handshake
	 * rows and the same value pl_csrf_session_id() resolves to, so the
	 * intent, the handshake and the resulting reauth_grants row all
	 * agree on one identifier.
	 */
	function pl_sso_reauth_session_id()
	{
		$sid = session_id();
		
		return (is_string($sid) && strlen($sid) > 0) ? $sid : null;
	}
}


if (!function_exists('pl_sso_reauth_refuse'))
{
	/**
	 * @return void
	 * @param string $reason audit reason code
	 * @param string $message one sentence for the browser
	 * @desc Refuse a re-auth start, record it, and stop.
	 */
	function pl_sso_reauth_refuse($reason, $message)
	{
		pl_audit('reauth.denied', null, null, array(
			'reason' => $reason,
			'method' => 'sso',
		));
		
		header('HTTP/1.1 403 Forbidden');
		header('Content-Type: text/plain; charset=utf-8');
		echo $message . "\n";
		exit();
	}
}


if (!function_exists('pl_sso_reauth_session_user'))
{
	/**
	 * @return array|null user_id, username, auth_method, sso_subject
	 * @desc The user behind the current session, read from
	 * user_sessions rather than from anything the request supplied.
	 * These endpoints run under PL_DISABLE_SECURITY, so this lookup is
	 * the only thing between a stranger's POST and a re-auth grant.
	 */
	function pl_sso_reauth_session_user()
	{
		$sid = pl_sso_reauth_session_id();
		
		if (is_null($sid))
		{
			return null;
		}
		
		$result = DB::preparedQuery(
			'SELECT users.user_id, users.username, users.auth_method, users.sso_subject
				FROM user_sessions
				JOIN users ON users.user_id = user_sessions.user_id
				WHERE user_sessions.session_id = ?
				AND (user_sessions.logout IS NULL OR user_sessions.logout = 0)
				AND users.enabled = \'1\'
				LIMIT 1',
			array($sid)
		);
		
		if (!$result || DBResult::numRows($result) != 1)
		{
			return null;
		}
		
		$row = DBResult::fetchRow($result);
		
		return is_array($row) ? $row : null;
	}
}


if (!function_exists('pl_sso_reauth_sanitize_return'))
{
	/**
	 * @return string a path beginning with '/', relative to base_url
	 * @param string $raw the submitted return path
	 * @desc Reduce a submitted return path to something that can only
	 * land inside this deployment. Anything carrying a scheme, a host, a
	 * backslash or a leading '//' is discarded rather than repaired: the
	 * fallback '/' is harmless, and a value that cannot be fully
	 * understood is not worth redirecting to.
	 */
	function pl_sso_reauth_sanitize_return($raw)
	{
		/*	Control characters go first. They could otherwise split the
			Location header, and they must not survive to be checked
			around by the tests below.
		*/
		$raw = preg_replace('/[\x00-\x1F\x7F]/', '', (string) $raw);
		$raw = trim($raw);
		
		if ('' === $raw || '/' !== $raw[0] || strlen($raw) > 512)
		{
			return '/';
		}
		
		/*	'//host' is protocol-relative and leaves the site, and some
			browsers treat a backslash as a separator, so it can do the
			same.
		*/
		if (0 === strpos($raw, '//') || false !== strpos($raw, '\\'))
		{
			return '/';
		}
		
		// A colon in the path portion invites scheme confusion.
		$path_only = strtok($raw, '?');
		
		if (false !== strpos((string) $path_only, ':'))
		{
			return '/';
		}
		
		return $raw;
	}
}


if (!function_exists('pl_sso_reauth_store_intent'))
{
	/**
	 * @return void
	 * @param string $scope one of pl_reauth_scopes()
	 * @param string $return a path already through pl_sso_reauth_sanitize_return()
	 * @desc Record a re-auth intent for the current session.
	 */
	function pl_sso_reauth_store_intent($scope, $return)
	{
		$sid = pl_sso_reauth_session_id();
		
		if (is_null($sid))
		{
			return;
		}
		
		$sql = 'INSERT INTO pika_sso_oidc_state (session_id, state_key, state_value)
			VALUES (?, ?, ?)
			ON DUPLICATE KEY UPDATE state_value = VALUES(state_value),
				created_at = CURRENT_TIMESTAMP';
		
		DB::preparedQuery($sql, array($sid, PL_SSO_REAUTH_KEY_SCOPE, (string) $scope));
		DB::preparedQuery($sql, array($sid, PL_SSO_REAUTH_KEY_RETURN, (string) $return));
	}
}


if (!function_exists('pl_sso_reauth_take_intent'))
{
	/**
	 * @return array|null array('scope' => ..., 'return' => ...)
	 * @desc Read the stored intent for the current session and delete
	 * it. Single-use by construction: the rows go whether or not the
	 * caller goes on to issue a grant, so a replayed callback cannot
	 * mint a second one.
	 */
	function pl_sso_reauth_take_intent()
	{
		$sid = pl_sso_reauth_session_id();
		
		if (is_null($sid))
		{
			return null;
		}
		
		$result = DB::preparedQuery(
			'SELECT state_key, state_value FROM pika_sso_oidc_state
				WHERE session_id = ? AND state_key IN (?, ?)',
			array($sid, PL_SSO_REAUTH_KEY_SCOPE, PL_SSO_REAUTH_KEY_RETURN)
		);
		
		if (!$result)
		{
			return null;
		}
		
		$found = array();
		
		while ($row = DBResult::fetchRow($result))
		{
			$found[$row['state_key']] = $row['state_value'];
		}
		
		if (!isset($found[PL_SSO_REAUTH_KEY_SCOPE]))
		{
			return null;
		}
		
		DB::preparedQuery(
			'DELETE FROM pika_sso_oidc_state WHERE session_id = ? AND state_key IN (?, ?)',
			array($sid, PL_SSO_REAUTH_KEY_SCOPE, PL_SSO_REAUTH_KEY_RETURN)
		);
		
		return array(
			'scope'  => (string) $found[PL_SSO_REAUTH_KEY_SCOPE],
			'return' => isset($found[PL_SSO_REAUTH_KEY_RETURN]) ? (string) $found[PL_SSO_REAUTH_KEY_RETURN] : '/',
		);
	}
}


if (!function_exists('pl_sso_reauth_grant'))
{
	/**
	 * @return int the number of seconds the grant is good for
	 * @param string $sid the session id to attach the grant to
	 * @param string $scope the action scope
	 * @param int $user_id for the audit entry
	 * @desc Write the grant that satisfies pl_reauth_required() for this
	 * scope.
	 */
	function pl_sso_reauth_grant($sid, $scope, $user_id)
	{
		$window = defined('PL_REAUTH_WINDOW_SECONDS') ? (int) PL_REAUTH_WINDOW_SECONDS : 300;
		
		DB::preparedQuery(
			'INSERT INTO reauth_grants (session_id, action_scope, granted_until)
				VALUES (?, ?, DATE_ADD(NOW(), INTERVAL ? SECOND))
				ON DUPLICATE KEY UPDATE granted_until = VALUES(granted_until)',
			array((string) $sid, (string) $scope, $window)
		);
		
		pl_audit('reauth.granted', 'user', (int) $user_id, array(
			'scope'  => $scope,
			'window' => $window,
			'method' => 'sso',
		));
		
		return $window;
	}
}

?>
