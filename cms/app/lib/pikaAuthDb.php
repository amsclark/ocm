<?php

/**********************************/
/* Pika CMS (C) 2011              */
/* Pika Software, LLC             */
/* http://pikasoftware.com        */
/**********************************/


/**
* pikaAuthDb class - class for pikaAuth
* implementing user/password verification against a database table
*
* @author Matthew Friedlander <matt@pikasoftware.com>;
* @version 1.0
* @package Danio
*/
class pikaAuthDb 
{
	private $table_name = 'users';
	private $identity_column = 'username';
	private $credential_column = 'password';
	
	protected $is_authorized = false;
	protected $auth_row = array();
	protected $messages = array();
	
	/*	A pre-computed bcrypt hash of an arbitrary string, used as a target
		for password_verify() on the "no such user" branch so that branch
		costs about the same wall-clock time as verifying a real password.
		Without it the login page answers an unknown username almost
		instantly and a known one after a full bcrypt round, which is enough
		to enumerate valid usernames from timing alone (CWE-208).
		
		Generated once with: password_hash('a dummy value', PASSWORD_DEFAULT)
		The value itself does not matter, only that it is a valid hash at the
		same cost factor as the stored ones.
	*/
	const DUMMY_PASSWORD_HASH = '$2y$10$DwOAV.Af5HP2VOk0uAoRwe4j/XUWU5tFaahAJsdPiMd9xRyh.1KMm';
	
	/*	The one failure message shown for every bad login, whatever actually
		went wrong. The two branches used to word it differently -- a known
		username with a bad password said "The Login Credentials you
		supplied are invalid" from one place and an unknown username said the
		same string from another -- and any future divergence in that wording
		enumerates usernames from the response body (CWE-204), which is the
		same leak DUMMY_PASSWORD_HASH closes on the timing side. One
		constant, used by every branch, cannot drift.
		
		It names the MFA code as a possible cause without saying whether the
		code was the part that failed. Telling a caller "your password was
		right but the code was wrong" confirms a valid username and password
		pair (CWE-209); the specific reason goes to the server error log and
		the audit log instead.
	*/
	const GENERIC_LOGIN_FAILURE = 'The credentials you supplied are invalid. '
		. 'Please re-check your Username, Password, and MFA code (if configured) and try again.';
	
	
	
	/**
	 * public function __construct
	 * 
	 * Initializes key properties of the pikaAuthDb class to prepare to verify
	 * provided credentials for authorization
	 *
	 * @param string $table_name = name of the database table to check
	 * @param string $identity_column = name of the column in $table_name containing user identity (e.g. username)
	 * @param string $credential_column = name of the column in $table_name containing user credential (e.g. password)
	 * @param string $deprecated = DEPRECATED; was name of DB supported function for hashing credential (i.e. MD5, PASSWORD)
	 */
	public function __construct($table_name = null,$identity_column = null,$credential_column = null,$deprecated = null)
	{
		$this->setTableName($table_name);
		if(!is_null($identity_column) && strlen($identity_column) > 0)
		{
			$this->identity_column = $identity_column;			
		}
		if(!is_null($credential_column) && strlen($credential_column) > 0)
		{
			$this->credential_column = $credential_column;		
		}
	}
	
	/**
	 * public function setTableName(
	 *
	 * @param string $table_name - sets the name of the table to query for identities.
	 */
	public function setTableName($table_name = null)
	{
		if(!is_null($table_name) && strlen($table_name))
		{
			$this->table_name = $table_name;
		}
	}
	
	/**
	 * Verify a username, a password, and the second factor when the account
	 * has one enrolled.
	 *
	 * @param string|null $identity   submitted username
	 * @param string|null $credential submitted password
	 * @param string|null $totp       submitted six-digit code, or null
	 * @return bool
	 */
	public function authenticate($identity = null,$credential = null,$totp = null)
	{
		/*	Reset every piece of per-call state, not just the flag. A reused
			instance otherwise carries a previous successful auth_row, and the
			messages from a previous attempt, into this one (CWE-284).
		*/
		$this->is_authorized = false;
		$this->auth_row = array();
		$this->messages = array();
		
		if(!is_null($identity) && strlen($identity) > 0 && strlen($this->table_name) > 0)
		{
			$safe_identity = DB::escapeString($identity);
			
			/*	The TOTP columns are named only when they exist. add_totp.sql
				is applied by the container entrypoint, but a hand-installed
				deployment may not have run it, and MariaDB rejects a whole
				SELECT that names an absent column -- which would lock every
				user out of the application. The guard is not a fallback for
				the feature; it is what keeps login working without it.
			*/
			$totp_columns = '';
			if(self::columnExists($this->table_name,'totp_secret'))
			{
				$totp_columns = ', users.totp_enabled, users.totp_secret';
			}
			
			/*	Same guard, same reason, for the single sign-on column.
				add_sso.sql may not have been applied.
			*/
			$sso_columns = '';
			if(self::columnExists($this->table_name,'auth_method'))
			{
				$sso_columns = ', users.auth_method';
			}
			
			$sql  = "SELECT user_id, username, enabled, password_expire, 
					users.group_id AS group_name, `groups`.*, password{$totp_columns}{$sso_columns}
					FROM {$this->table_name}
					LEFT JOIN `groups` ON users.group_id=groups.group_id
					WHERE enabled = '1'
					AND username=?
					AND LENGTH(password) > 0";
			$result = self::identityQuery($sql,$identity);
			
			if (DBResult::numRows($result) == 1)
			{
				if (PHP_VERSION_ID >= 50303)
				{
					require_once('password_hash_compat.php');
				}
				
				$row = DBResult::fetchRow($result);
				
				/*	An account that signs in through the identity provider
					does not sign in here, even if a password hash is still
					on the row. pikaAuthSso::autobind() blanks the password
					when it binds an account, and the SELECT above requires a
					non-empty password, so a bound account never reaches this
					point -- but an administrator can also set the sign-in
					method by hand on the account form, and that account must
					be refused too rather than keeping a second way in.
					
					Refused behind the same generic message as a wrong
					password: which accounts an organisation has moved to
					single sign-on is not something the login page should
					answer.
				*/
				$row_auth_method = isset($row['auth_method']) ? (string) $row['auth_method'] : 'password';
				
				if ('sso' === $row_auth_method)
				{
					/*	Spend the bcrypt round anyway, and discard it, so
						that response time does not say which accounts have
						been moved to single sign-on (CWE-208).
					*/
					@password_verify((string) $credential, self::DUMMY_PASSWORD_HASH);
					
					pl_audit('login.failure', 'user', $row['user_id'], array('reason' => 'auth_method_sso'), $row['user_id'], $row['username']);
					$this->setMessage('0100',self::GENERIC_LOGIN_FAILURE,__FILE__,__LINE__);
					
					return $this->is_authorized;
				}
				
				/*	The second factor. The stored secret is ciphertext at
					rest, so decrypt it first; pl_totp_decrypt() returns a
					value written in cleartext by hand unchanged, so a row
					that predates the encryption still works.
					
					An enrolled account whose secret will not decrypt fails
					closed. Treating a missing or broken encryption key as
					"no MFA on this account" would silently downgrade every
					enrolled user to a password alone, which is the opposite
					of what enrolling asked for.
					
					$totp_window holds the window index of the accepted code
					so it can be burned AFTER the password check passes.
					Burning it here would let somebody holding only the
					authenticator -- with no password -- walk the user's
					codes and lock them out of their own account.
				*/
				require_once(dirname(__FILE__) . '/pikaCrypto.php');
				$stored_secret = isset($row['totp_secret']) ? (string) $row['totp_secret'] : '';
				$totp_window = null;
				
				if (strlen($stored_secret) > 0)
				{
					$secret = pl_totp_decrypt($stored_secret);
					
					if (false === $secret || 0 === strlen($secret))
					{
						$totp_ok = false;
					}
					
					else
					{
						$totp_window = pl_totp_verify_once($row['user_id'],$secret,(string) $totp);
						$totp_ok = (false !== $totp_window);
					}
				}
				
				else
				{
					$totp_ok = true;
				}
				
				// one user record matched the username and password
				if (PHP_VERSION_ID >= 50303 && password_verify((string) $credential, (string) $row['password']) && $totp_ok)
				{  // Identity & Credential match existing records - allow login
					$this->is_authorized = true;
					$this->auth_row = $row;
					
					if (password_needs_rehash($row['password'], PASSWORD_DEFAULT)) 
					{
						require_once('pikaUser.php');
						$u = new pikaUser($row['user_id']);
						$u->setValue('password', password_hash($credential, PASSWORD_DEFAULT));
						$u->save();
    				}
					
					if (null !== $totp_window)
					{
						pl_totp_mark_used($row['user_id'],$totp_window);
					}
					
					pl_audit('login.success', 'user', $row['user_id'], null, $row['user_id'], $row['username']);
				}
				
				else if (md5($credential) == $row['password'] && $totp_ok)
				{
					$this->is_authorized = true;
					$this->auth_row = $row;
					
					if (PHP_VERSION_ID >= 50303)
					{
						/*	While we have the password in memory, replace the 
							stored md5 value with a password_hash value.
							*/
						require_once('pikaUser.php');
						$u = new pikaUser($row['user_id']);
						$u->setValue('password', password_hash($credential, PASSWORD_DEFAULT));
						$u->save();
					}
					
					if (null !== $totp_window)
					{
						pl_totp_mark_used($row['user_id'],$totp_window);
					}
					
					pl_audit('login.success', 'user', $row['user_id'], array('note' => 'legacy_md5_upgraded'), $row['user_id'], $row['username']);
				}
				
				else 
				{  // No matching user credentials found - pass login error			
					/*	Work out which half failed for the log only. The
						caller is told nothing more than that the attempt was
						refused.
					*/
					$password_ok = (PHP_VERSION_ID >= 50303 && password_verify((string) $credential, (string) $row['password']))
						|| md5($credential) == $row['password'];
					
					if (!$password_ok)
					{
						pl_audit('login.failure', 'user', $row['user_id'], array('reason' => 'bad_password'), $row['user_id'], $row['username']);
					}
					
					elseif (!$totp_ok)
					{
						error_log('MFA code invalid for user ' . $row['username']);
						pl_audit('login.failure', 'user', $row['user_id'], array('reason' => 'bad_totp'), $row['user_id'], $row['username']);
					}
					
					else
					{
						pl_audit('login.failure', 'user', $row['user_id'], array('reason' => 'unknown'), $row['user_id'], $row['username']);
					}
					
					$this->setMessage('0100',self::GENERIC_LOGIN_FAILURE,__FILE__,__LINE__);
				}
			}
			
			else
			{
				/*	Reached when the query did not return exactly one row: an
					unknown username, a disabled account, or an account with
					a blank password. Spend a bcrypt round against the dummy
					hash so this branch costs about what the branch above
					costs; the return value is deliberately discarded. Without
					it, response time alone says whether a username exists
					(CWE-208).
				*/
				@password_verify((string) $credential, self::DUMMY_PASSWORD_HASH);
				
				// Log the attempted username, truncated, so operators can spot
				// credential stuffing. Never log the credential itself.
				pl_audit('login.failure', null, null, array('reason' => 'no_matching_user', 'attempted_username' => substr((string)$identity, 0, 64)));
				$this->setMessage('0100',self::GENERIC_LOGIN_FAILURE,__FILE__,__LINE__);
			}
			
		}
		elseif(!is_null($identity))
		{ 
				// No matching session - no username provided - pass no user login error
				$msgstr = 'Username provided is blank.  Please re-enter your Username, Password, and MFA code (if configured) and try again';
				$this->setMessage('0101',$msgstr,__FILE__,__LINE__);	
		}
		
		return $this->is_authorized;
	}
	
	/**
	 * Run the login SELECT with the submitted username bound, not
	 * interpolated.
	 *
	 * $sql must carry exactly one placeholder, "username=?".
	 *
	 * DB::preparedQuery throws on a build with no mysqli, which is PHP 5
	 * only, and login has to keep working there. That is the one case the
	 * catch covers: it rewrites the placeholder with an escaped literal and
	 * runs the query the old way. The escaping is the same call the query
	 * used before it was parameterised, so the fallback is no weaker than
	 * the code it replaces -- it is just not proof against a future edit
	 * that forgets to escape.
	 *
	 * @param string $sql
	 * @param string $identity
	 * @return mixed
	 */
	private static function identityQuery($sql,$identity)
	{
		try
		{
			return DB::preparedQuery($sql,array($identity));
		}
		
		catch (Exception $e)
		{
			$literal = "username='" . DB::escapeString($identity) . "'";
			$fallback = str_replace('username=?',$literal,$sql);
			$result = DB::query($fallback);
			
			if (false === $result)
			{
				trigger_error("SQL: " . $fallback . " Error: " . DB::error());
			}
			
			return $result;
		}
	}
	
	/**
	 * Whether $column exists on $table.
	 *
	 * Lets the login SELECT name an optional column only where the
	 * migration that adds it has been applied. SHOW COLUMNS takes no
	 * placeholders in MariaDB, so the identifiers are escaped and the
	 * pattern is a literal. Memoised for the request, and fails closed: any
	 * error leaves the column out of the SELECT.
	 *
	 * @param string $table
	 * @param string $column
	 * @return bool
	 */
	private static function columnExists($table,$column)
	{
		static $cache = array();
		
		$key = $table . '.' . $column;
		
		if (isset($cache[$key]))
		{
			return $cache[$key];
		}
		
		$cache[$key] = false;
		
		try
		{
			$safe_table = DB::escapeString($table);
			$safe_column = DB::escapeString($column);
			$result = DB::query("SHOW COLUMNS FROM `{$safe_table}` LIKE '{$safe_column}'");
			
			if ($result && DBResult::numRows($result) > 0)
			{
				$cache[$key] = true;
			}
		}
		
		catch (Exception $e)
		{
			$cache[$key] = false;
		}
		
		return $cache[$key];
	}
	
	public function getAuthRow()
	{
		return $this->auth_row;
	}
	
	public function setMessage($msgno = null, $msgstr = null, $msgfile = null, $msgline = null)
	{
		$this->messages[] = array($msgno,$msgstr,$msgfile,$msgline);
	}
	
	public function getMessages()
	{
		return $this->messages;
	}
	
	
}

?>
