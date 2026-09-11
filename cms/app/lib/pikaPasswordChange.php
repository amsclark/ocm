<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

/*	The forced password change, and the gate that insists on it.
	
	Two things set users.must_change_password:
	
	  - The container entrypoint, when it generates the first password for
	    the bootstrap account. That value is printed to the container log,
	    where it stays for as long as the log does, so it has to be spent
	    once and replaced rather than left in service.
	  - system-users.php, when an administrator sets somebody else's
	    password. Until the account holder picks their own, the password is
	    a credential two people know, and only one of them is accountable
	    for what is done with it.
	
	While the flag is set the user may load password.php, enroll_mfa.php and
	logout.php. Every other page sends them back to password.php. Picking a
	new password clears the flag.
	
	It fails open, for the same reason cms/app/lib/pikaMfaEnroll.php does: a
	bug in a gate that runs in front of every page costs more than the
	feature it enforces.
	*/


if (!function_exists('pl_password_change_schema_ready'))
{
	/**
	 * Whether add_must_change_password.sql has been applied.
	 *
	 * Cached per request. An installation that has not run the upgrade has
	 * no column to read and no forced change to enforce.
	 *
	 * @return bool
	 */
	function pl_password_change_schema_ready()
	{
		static $ready = null;
		
		if (!is_null($ready))
		{
			return $ready;
		}
		
		$ready = false;
		
		try
		{
			$columns = DB::query("SHOW COLUMNS FROM `users` LIKE 'must_change_password'");
			$ready = ($columns && DBResult::numRows($columns) > 0);
		}
		
		catch (Exception $e)
		{
			$ready = false;
		}
		
		return $ready;
	}
}


if (!function_exists('pl_password_change_required'))
{
	/**
	 * True when this account owes a password change.
	 *
	 * @param int $user_id
	 * @return bool
	 */
	function pl_password_change_required($user_id)
	{
		$user_id = (int) $user_id;
		
		if ($user_id <= 0 || !pl_password_change_schema_ready())
		{
			return false;
		}
		
		$row = null;
		
		try
		{
			$rs = DB::preparedQuery(
				"SELECT must_change_password FROM users WHERE user_id = ? AND enabled = '1'",
				array($user_id)
			);
			
			if ($rs && DBResult::numRows($rs) == 1)
			{
				$row = DBResult::fetchRow($rs);
			}
		}
		
		catch (Exception $e)
		{
			return false;
		}
		
		if (!is_array($row) || 1 !== (int) $row['must_change_password'])
		{
			return false;
		}
		
		/*	An account that signs in through the identity provider has no
			password here to change. The flag can still be set on one: an
			account that used to sign in with a password and was moved to
			single sign-on afterwards. Sending that user to password.php
			would trap them on a form that cannot help them, so the flag is
			ignored for them. system-users.php clears it when it moves an
			account to single sign-on; this covers the rows that were moved
			some other way.
		*/
		require_once(dirname(__FILE__) . '/pikaSsoOidc.php');
		
		if (pl_sso_user_is_sso($user_id))
		{
			return false;
		}
		
		return true;
	}
}


if (!function_exists('pl_password_change_set'))
{
	/**
	 * Set or clear the flag on one account.
	 *
	 * Written with its own statement rather than through pikaUser, so that
	 * an installation without the upgrade applied keeps working and so that
	 * the column is not reachable from a posted field name.
	 *
	 * @param int $user_id
	 * @param bool $required
	 * @return bool	Whether the write happened.
	 */
	function pl_password_change_set($user_id, $required)
	{
		$user_id = (int) $user_id;
		
		if ($user_id <= 0 || !pl_password_change_schema_ready())
		{
			return false;
		}
		
		try
		{
			DB::preparedQuery(
				"UPDATE users SET must_change_password = ? WHERE user_id = ? LIMIT 1",
				array(($required) ? '1' : '0', $user_id)
			);
		}
		
		catch (Exception $e)
		{
			error_log('pl_password_change_set: ' . $e->getMessage());
			
			return false;
		}
		
		return true;
	}
}


if (!function_exists('pl_password_change_gate'))
{
	/**
	 * Per-request gate. Call it after authenticate(). Sends a user who owes
	 * a password change to password.php and does nothing to anybody else.
	 *
	 * @return void
	 */
	function pl_password_change_gate()
	{
		try
		{
			$script_path = isset($_SERVER['SCRIPT_NAME']) ? (string) $_SERVER['SCRIPT_NAME'] : '';
			$script = basename($script_path);
			
			/*	The page that completes the change, and the way out.
				enroll_mfa.php is here because the multi-factor gate in
				pikaMfaEnroll.php runs first and redirects to it: without
				this entry the two gates would send the browser back and
				forth between their own pages forever. Enrollment finishes
				first, then the password change.
			*/
			$allow = array('password.php','enroll_mfa.php','logout.php');
			
			if (in_array($script,$allow,true))
			{
				return;
			}
			
			/*	A /services/ endpoint is ajax and expects JSON. A redirect
				body would be parsed as if it were the answer. The decision
				is the same; only the shape of the refusal changes. Waiving
				the gate for /services/ instead would enforce the change on
				the front door only, and most of the reads and writes in
				this application go through services/*-server-ajax.php.
			*/
			$is_service = (strpos($script_path,'/services/') !== false);
			
			if (!class_exists('pikaAuth'))
			{
				return;
			}
			
			$row = pikaAuth::getInstance()->getAuthRow();
			$uid = (is_array($row) && isset($row['user_id'])) ? (int) $row['user_id'] : 0;
			
			if ($uid <= 0)
			{
				// Before login, or an endpoint that authenticates with a
				// shared secret and has no user session at all.
				return;
			}
			
			if (pl_password_change_required($uid))
			{
				$base = (string) pl_settings_get('base_url');
				
				if ($is_service)
				{
					if (!headers_sent())
					{
						header('HTTP/1.1 403 Forbidden');
						header('Content-Type: application/json; charset=utf-8');
					}
					
					echo json_encode(array(
						'error' => 'password_change_required',
						'message' => 'You must set a new password before you can continue.',
						'redirect' => $base . '/password.php?must_change=1'
					));
					
					exit();
				}
				
				/*	303 rather than the usual 302. The request that trips
					this gate most often is the login POST itself, and a 302
					tells the browser to repeat that POST against
					password.php. The repeated body carries the login fields
					and no CSRF token, so it is refused and the user sees an
					error instead of the form. 303 turns the follow-up into
					a GET, which pl_csrf_check() lets through.
				*/
				header('Location: ' . $base . '/password.php?must_change=1', true, 303);
				exit();
			}
		}
		
		catch (Exception $e)
		{
			error_log('pl_password_change_gate fail-open: ' . $e->getMessage());
			
			return;
		}
	}
}
