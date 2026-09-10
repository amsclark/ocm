<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

/*	The pikaAuth adapter for a completed OpenID Connect sign-in.
	
	By the time this class is constructed the ID token has already been
	verified: signature, issuer, audience, expiry and nonce. What is left is
	the question this class answers -- which local account, if any, that
	verified identity is -- and it is deliberately the only place that
	question is answered.
	
	Going through pikaAuth's adapter interface rather than establishing a
	session directly is the point. Session creation, the identifier
	regeneration that goes with it, the CSRF rotation, the maintenance-mode
	check and the audit trail all live in pikaAuth::authenticate() already. A
	second copy of that sequence written for SSO is a second copy that can
	fall behind the first, and the half most likely to be forgotten is the
	half that rotates something.
*/

require_once(dirname(__FILE__) . '/pikaSsoOidc.php');


class pikaAuthSso
{
	protected $claims = array();
	protected $config = array();
	
	protected $is_authorized = false;
	protected $auth_row = array();
	protected $messages = array();
	
	/*	The failure the browser is shown, whatever went wrong. The reason is
		recorded in the audit log instead.
		
		Being specific here would answer questions for anybody who can reach
		the callback: whether an address is a user of this system, whether an
		account is disabled, whether it has been migrated to SSO. Any of those
		is worth something to somebody enumerating an organisation's staff,
		and none of them helps the person actually trying to sign in, who
		needs to talk to an administrator either way.
	*/
	const GENERIC_SSO_FAILURE = 'Your sign-in at the identity provider succeeded, but this '
		. 'application could not sign you in. Please ask your administrator to check that your '
		. 'account is set up for single sign-on.';
	
	/**
	 * @param array $claims the verified ID-token claims
	 * @param array $config pl_sso_config()
	 */
	public function __construct(array $claims, array $config)
	{
		$this->claims = $claims;
		$this->config = $config;
	}
	
	/**
	 * The pikaAuth adapter entry point. The three arguments are the username,
	 * the password and the second factor; none of them applies to a sign-in
	 * that already happened somewhere else, and all three are ignored.
	 *
	 * @param string|null $identity   ignored
	 * @param string|null $credential ignored
	 * @param string|null $totp       ignored
	 * @return bool
	 */
	public function authenticate($identity = null, $credential = null, $totp = null)
	{
		$this->is_authorized = false;
		$this->auth_row = array();
		$this->messages = array();
		
		$sub = isset($this->claims['sub']) ? (string) $this->claims['sub'] : '';
		
		if ('' === $sub)
		{
			return $this->refuse('missing_sub_claim', null, null);
		}
		
		$row = $this->rowForSubject($sub);
		
		if (!is_array($row))
		{
			/*	No account carries this subject. Either it has not been linked
				yet, or auto-binding is meant to link it now.
			*/
			$row = $this->autobind($sub);
			
			if (!is_array($row))
			{
				return $this->refuse('no_matching_user', null, array(
					'sub_preview' => substr($sub, 0, 16)
				));
			}
		}
		
		if ('1' !== (string) $row['enabled'])
		{
			return $this->refuse('account_disabled', $row['user_id'], array(
				'username' => $row['username']
			));
		}
		
		/*	The account has to be flagged for SSO, not merely carry a subject.
			An administrator who pastes a subject onto a password account has
			not yet decided to migrate it, and until they do the password is
			still the credential that account is checked against.
		*/
		if ('sso' !== (string) $row['auth_method'])
		{
			return $this->refuse('auth_method_not_sso', $row['user_id'], array(
				'username' => $row['username']
			));
		}
		
		$this->is_authorized = true;
		$this->auth_row = $this->authRowFor($row['user_id']);
		
		if (!is_array($this->auth_row) || !isset($this->auth_row['user_id']))
		{
			$this->is_authorized = false;
			
			return $this->refuse('user_row_unreadable', $row['user_id'], null);
		}
		
		pl_audit('sso.login.success', 'user', $row['user_id'], array(
			'provider' => $this->config['provider'],
			'username' => $row['username']
		), $row['user_id'], $row['username']);
		
		return true;
	}
	
	/**
	 * The single account carrying this OIDC subject, or null.
	 *
	 * Two accounts carrying the same subject is a configuration error an
	 * administrator made, and it has to refuse rather than pick one: picking
	 * one means the answer to "whose account does this identity open"
	 * depends on row order.
	 *
	 * @param string $sub
	 * @return array|null
	 */
	protected function rowForSubject($sub)
	{
		$result = DB::preparedQuery(
			'SELECT user_id, username, enabled, auth_method FROM users
				WHERE sso_subject = ? AND LENGTH(sso_subject) > 0 LIMIT 2',
			array($sub)
		);
		
		if (!$result)
		{
			return null;
		}
		
		$rows = array();
		
		while ($row = DBResult::fetchRow($result))
		{
			$rows[] = $row;
		}
		
		if (count($rows) > 1)
		{
			$this->refuse('duplicate_sso_subject', null, array(
				'sub_preview' => substr((string) $sub, 0, 16)
			));
			
			return null;
		}
		
		return isset($rows[0]) ? $rows[0] : null;
	}
	
	/**
	 * Link this subject to an existing account matched on the provider's
	 * verified email address, and return that account.
	 *
	 * This is the bulk-onboarding path: copying every user's subject out of
	 * the directory by hand does not scale, so the first successful sign-in
	 * does it. What it will not do is create anything. There is still no
	 * auto-provisioning, and an address the provider will issue a token for
	 * that matches no account here is still refused.
	 *
	 * The domain allowlist is required, not optional. An empty allowlist
	 * refuses every bind. Reading "blank" as "any domain" would mean an
	 * administrator who turned auto-binding on and left the next field alone
	 * had accepted every address the provider is willing to assert, which for
	 * a multi-tenant provider is every address in the world.
	 *
	 * @param string $sub
	 * @return array|null
	 */
	protected function autobind($sub)
	{
		if (empty($this->config['autobind']))
		{
			return null;
		}
		
		$email = pl_sso_verified_email($this->claims, $this->config);
		
		if ('' === $email)
		{
			$this->refuse('autobind_no_verified_email', null, null);
			
			return null;
		}
		
		$at = strrpos($email, '@');
		$domain = (false === $at) ? '' : substr($email, $at + 1);
		
		if ('' === $domain || !in_array($domain, $this->config['autobind_domains'], true))
		{
			$this->refuse('autobind_domain_not_allowed', null, array('domain' => $domain));
			
			return null;
		}
		
		/*	Exactly one enabled account, with the address the provider
			asserted and no subject of its own yet. A disabled leaver sharing
			an address with a live colleague must not block the live one, and
			an account already bound to another subject must not be rebound by
			a sign-in.
		*/
		$result = DB::preparedQuery(
			"SELECT user_id, username, enabled, auth_method FROM users
				WHERE LOWER(email) = ? AND enabled = '1'
				AND (sso_subject IS NULL OR LENGTH(sso_subject) = 0) LIMIT 2",
			array($email)
		);
		
		$rows = array();
		
		if ($result)
		{
			while ($row = DBResult::fetchRow($result))
			{
				$rows[] = $row;
			}
		}
		
		if (1 !== count($rows))
		{
			$this->refuse(0 === count($rows) ? 'autobind_no_match' : 'autobind_ambiguous',
				null, array('email_domain' => $domain));
			
			return null;
		}
		
		$row = $rows[0];
		
		/*	Binding clears the local credential and the piece of policy that
			only a local credential can satisfy. Leaving password_expire set
			would bounce the user back to the sign-in page on their next
			request with no way to clear it, because the page that clears it
			asks for the password they no longer have.
		*/
		DB::preparedQuery(
			"UPDATE users SET auth_method = 'sso', sso_subject = ?, password = '',
				password_expire = 0
				WHERE user_id = ? AND (sso_subject IS NULL OR LENGTH(sso_subject) = 0) LIMIT 1",
			array($sub, $row['user_id'])
		);
		
		$row['auth_method'] = 'sso';
		
		pl_audit('sso.autobind', 'user', $row['user_id'], array(
			'provider'    => $this->config['provider'],
			'username'    => $row['username'],
			'sub_preview' => substr((string) $sub, 0, 16)
		), $row['user_id'], $row['username']);
		
		return $row;
	}
	
	/**
	 * The row pikaAuth stores as the authenticated user: the same shape the
	 * password adapter hands back, without the password column.
	 *
	 * @param int $user_id
	 * @return array|null
	 */
	protected function authRowFor($user_id)
	{
		$result = DB::preparedQuery(
			'SELECT users.user_id, users.username, users.enabled, users.password_expire,
					users.group_id AS group_name, `groups`.*
				FROM users
				LEFT JOIN `groups` ON users.group_id = groups.group_id
				WHERE users.user_id = ? LIMIT 1',
			array((int) $user_id)
		);
		
		if (!$result || DBResult::numRows($result) != 1)
		{
			return null;
		}
		
		return DBResult::fetchRow($result);
	}
	
	/**
	 * Record why the sign-in was refused and set the one generic message.
	 *
	 * @param string     $reason
	 * @param int|null   $user_id
	 * @param array|null $extra
	 * @return bool always false
	 */
	protected function refuse($reason, $user_id = null, $extra = null)
	{
		$details = is_array($extra) ? $extra : array();
		$details['reason'] = $reason;
		$details['provider'] = $this->config['provider'];
		
		$actor_id = null;
		$actor_name = null;
		
		if (isset($details['username']))
		{
			$actor_id = $user_id;
			$actor_name = $details['username'];
		}
		
		pl_audit('sso.login.failure', 'user', $user_id, $details, $actor_id, $actor_name);
		error_log('SSO sign-in refused: ' . $reason);
		$this->setMessage('0110', self::GENERIC_SSO_FAILURE, __FILE__, __LINE__);
		
		return false;
	}
	
	public function getAuthRow()
	{
		return $this->auth_row;
	}
	
	public function setMessage($msgno = null, $msgstr = null, $msgfile = null, $msgline = null)
	{
		$this->messages[] = array($msgno, $msgstr, $msgfile, $msgline);
	}
	
	public function getMessages()
	{
		return $this->messages;
	}
}
