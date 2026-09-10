<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

/*	Self-service MFA enrollment, and the gate that insists on it.
	
	An administrator turns MFA on for a user by setting totp_enabled = 1. That
	does not mint a secret, and it must not: a secret an administrator can see
	is a second factor the administrator also holds. So the account arrives at
	the next login enabled but not enrolled, and this gate sends it to
	enroll_mfa.php, and nowhere else, until it has a secret it can use.
	
	The scope is one user at a time. The gate fires only when THAT user's own
	account has totp_enabled = 1 and no readable secret. An account with MFA
	off, or with a working secret, never notices this file.
	
	It fails open. Every error is swallowed and the request proceeds. A bug in
	a gate that stands in front of every page is worth more than the feature
	it enforces: the worst case here is that enrollment is silently not
	forced, not that the whole staff is locked out of the application.
	*/

require_once(dirname(__FILE__) . '/pikaCrypto.php');


if (!function_exists('pl_mfa_user_must_enroll'))
{
	/**
	 * True when this account has MFA turned on but nothing to authenticate
	 * with yet.
	 *
	 * A secret that will not decrypt counts as "not enrolled". That is
	 * deliberate: the alternative is an account that can never log in
	 * again, because pikaAuthDb fails an undecryptable secret closed.
	 *
	 * @param int $user_id
	 * @return bool
	 */
	function pl_mfa_user_must_enroll($user_id)
	{
		$user_id = (int) $user_id;
		
		if ($user_id <= 0)
		{
			return false;
		}
		
		$row = null;
		
		try
		{
			$rs = DB::preparedQuery(
				"SELECT totp_enabled, totp_secret FROM users WHERE user_id = ? AND enabled = '1'",
				array($user_id)
			);
			
			if ($rs && DBResult::numRows($rs) == 1)
			{
				$row = DBResult::fetchRow($rs);
			}
		}
		
		catch (Exception $e)
		{
			/*	The likeliest cause is a deployment that has not applied
				add_totp.sql, where these columns do not exist. Nothing to
				enforce there.
			*/
			return false;
		}
		
		if (!is_array($row))
		{
			return false;
		}
		
		if (1 !== (int) $row['totp_enabled'])
		{
			return false;
		}
		
		$stored = (string) $row['totp_secret'];
		
		if (0 === strlen($stored))
		{
			return true;
		}
		
		$secret = pl_totp_decrypt($stored);
		
		return (false === $secret || 0 === strlen((string) $secret));
	}
}


if (!function_exists('pl_mfa_enroll_gate'))
{
	/**
	 * Per-request gate. Call it after authenticate(). Sends a user who owes
	 * an enrollment to enroll_mfa.php and does nothing to anybody else.
	 *
	 * @return void
	 */
	function pl_mfa_enroll_gate()
	{
		try
		{
			$script_path = isset($_SERVER['SCRIPT_NAME']) ? (string) $_SERVER['SCRIPT_NAME'] : '';
			$script = basename($script_path);
			
			// Never trap the enrollment page itself, the way out, or the
			// pre-login password reset.
			$allow = array('enroll_mfa.php','logout.php','resetpw.php');
			
			if (in_array($script,$allow,true))
			{
				return;
			}
			
			/*	A /services/ endpoint must not be answered with a 302. Those
				callers are ajax and expect JSON, and a redirect body gets
				parsed as if it were the answer.
				
				The response shape changes; the decision does not. Waiving the
				gate for /services/ instead would enforce MFA on the front
				door only -- most of the reads and writes in this application
				go through services/*-server-ajax.php, so an un-enrolled user
				would be stopped from loading a page and free to drive the
				whole application through ajax.
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
				/*	Not authenticated as a user: either before login, or one
					of the endpoints that authenticates with a shared secret
					and has no session at all. Nothing to gate either way.
				*/
				return;
			}
			
			if (pl_mfa_user_must_enroll($uid))
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
						'error' => 'mfa_enrollment_required',
						'message' => 'Multi-factor authentication enrollment is required before you can continue.',
						'redirect' => $base . '/enroll_mfa.php'
					));
					
					exit();
				}
				
				header('Location: ' . $base . '/enroll_mfa.php');
				exit();
			}
		}
		
		catch (Exception $e)
		{
			error_log('pl_mfa_enroll_gate fail-open: ' . $e->getMessage());
			
			return;
		}
	}
}
