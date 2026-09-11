<?php
/**********************************/
/* Pika CMS						  */
/* (C) 2011 Pika Software, LLC.   */
/* http://pikasoftware.com        */
/**********************************/

/*	Refuse, or warn about, a password that is already public.
	
	Length and character-class rules do not catch the passwords that
	actually get accounts taken over. Those are the ones already in a
	credential-stuffing list: Passw0rd!, Summer2024!, the organisation's
	own name with a digit on the end. All of them satisfy every strength
	rule this application has.
	
	The check asks Have I Been Pwned whether a candidate password appears in
	a published breach corpus. The password itself is never sent. It is
	hashed with SHA-1, the first five hex characters of that hash are sent,
	and the service answers with every hash it holds that begins with those
	five characters -- some hundreds of them. The comparison happens here.
	That is the k-anonymity model the service publishes; SHA-1 is what the
	service indexes on, and is not being relied on for anything else.
	
	What still leaves this server is: the fact that somebody set a password
	just now, and five hex characters. Some deployments will not want even
	that, which is why the whole thing is OFF until an administrator turns
	it on.
	
	Policy, in the password_breach_policy setting:
	
		off     never ask. The default.
		warn    tell the user, let the change through.
		block   refuse the change.
	
	A password is never refused because the service could not be reached.
	Somebody changing their password on a server with no route to the
	internet must still be able to change their password.
*/

if (!function_exists('pl_password_breach_policy'))
{
	/**
	 * The configured policy: 'off', 'warn' or 'block'.
	 *
	 * Anything else, including a blank or missing setting, is 'off'. A
	 * deployment that has not chosen does not make outbound requests.
	 *
	 * @return string
	 */
	function pl_password_breach_policy()
	{
		if (!function_exists('pl_settings_get'))
		{
			return 'off';
		}
		
		$policy = strtolower(trim((string) pl_settings_get('password_breach_policy')));
		
		if ('warn' === $policy || 'block' === $policy)
		{
			return $policy;
		}
		
		return 'off';
	}
}


if (!function_exists('pl_password_breach_endpoint'))
{
	/**
	 * The range endpoint to ask, without the five-character prefix.
	 *
	 * password_breach_api_url overrides it. There is deliberately no field
	 * for that on any administration screen: it exists so an automated test
	 * can stand up a local service instead of calling a real one, in the
	 * same way sso_allow_insecure_transport does for single sign-on.
	 *
	 * @return string
	 */
	function pl_password_breach_endpoint()
	{
		$override = function_exists('pl_settings_get')
			? trim((string) pl_settings_get('password_breach_api_url'))
			: '';
		
		if ('' !== $override)
		{
			return rtrim($override, '/');
		}
		
		return 'https://api.pwnedpasswords.com/range';
	}
}


if (!function_exists('pl_password_breach_count'))
{
	/**
	 * How many times this password appears in the breach corpora.
	 *
	 * @param string $plaintext the candidate password
	 * @return int 0 when it does not appear, the count when it does, and -1
	 *             when the service could not be reached
	 */
	function pl_password_breach_count($plaintext)
	{
		$plaintext = (string) $plaintext;
		
		if ('' === $plaintext)
		{
			return 0;
		}
		
		$hash   = strtoupper(sha1($plaintext));
		$prefix = substr($hash, 0, 5);
		$suffix = substr($hash, 5);
		$url    = pl_password_breach_endpoint() . '/' . $prefix;
		
		/*	Short timeouts on purpose. This runs while somebody is waiting
			for a form to submit, and the answer is advisory: a slow service
			must cost a second or two, not a minute.
			
			Add-Padding asks the service to pad its response to a fixed size,
			so that an observer counting bytes cannot work out which prefix
			was asked for.
		*/
		$body = false;
		
		if (function_exists('curl_init'))
		{
			$ch = curl_init($url);
			curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
			curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 2);
			curl_setopt($ch, CURLOPT_TIMEOUT, 4);
			curl_setopt($ch, CURLOPT_FOLLOWLOCATION, false);
			curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);
			curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, 2);
			curl_setopt($ch, CURLOPT_HTTPHEADER, array(
				'Add-Padding: true',
				'Accept: text/plain'
			));
			curl_setopt($ch, CURLOPT_USERAGENT, 'OCM (password breach check)');
			
			$response = curl_exec($ch);
			$status   = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
			curl_close($ch);
			
			if (false !== $response && 200 === $status)
			{
				$body = $response;
			}
		}
		
		else
		{
			$context = stream_context_create(array('http' => array(
				'method'        => 'GET',
				'timeout'       => 4,
				'ignore_errors' => false,
				'header'        => "Add-Padding: true\r\n"
					. "Accept: text/plain\r\n"
					. "User-Agent: OCM (password breach check)\r\n"
			)));
			
			$response = @file_get_contents($url, false, $context);
			
			if (false !== $response)
			{
				$body = $response;
			}
		}
		
		if (false === $body)
		{
			return -1;
		}
		
		/*	One "<35 hex characters>:<count>" per line. A few hundred lines,
			so a straight walk is quicker than building a lookup for one
			comparison.
		*/
		foreach (preg_split('/\r?\n/', $body) as $line)
		{
			$line = trim($line);
			
			if ('' === $line)
			{
				continue;
			}
			
			$parts = explode(':', $line, 2);
			
			if (count($parts) !== 2)
			{
				continue;
			}
			
			if (0 === strcasecmp($parts[0], $suffix))
			{
				return (int) trim($parts[1]);
			}
		}
		
		return 0;
	}
}


if (!function_exists('pl_password_breach_check'))
{
	/**
	 * The policy and the lookup together, as one verdict a caller can act
	 * on without knowing how either works.
	 *
	 * @param string $plaintext the candidate password
	 * @return array policy, count, verdict ('skipped', 'clean',
	 *               'compromised' or 'unreachable'), should_block, message
	 */
	function pl_password_breach_check($plaintext)
	{
		$policy = pl_password_breach_policy();
		
		if ('off' === $policy)
		{
			return array(
				'policy'       => 'off',
				'count'        => 0,
				'verdict'      => 'skipped',
				'should_block' => false,
				'message'      => ''
			);
		}
		
		$count = pl_password_breach_count($plaintext);
		
		if (-1 === $count)
		{
			/*	Never a refusal. A server that cannot reach the service must
				still let its users change their passwords.
			*/
			return array(
				'policy'       => $policy,
				'count'        => -1,
				'verdict'      => 'unreachable',
				'should_block' => false,
				'message'      => 'The breach-check service could not be reached, so this password was not checked against it.'
			);
		}
		
		if (0 === $count)
		{
			return array(
				'policy'       => $policy,
				'count'        => 0,
				'verdict'      => 'clean',
				'should_block' => false,
				'message'      => ''
			);
		}
		
		$message = 'This password appears in ' . number_format($count)
			. ' known data breach' . (1 === $count ? '' : 'es')
			. '. Anyone guessing passwords will try it. Please choose another.';
		
		return array(
			'policy'       => $policy,
			'count'        => $count,
			'verdict'      => 'compromised',
			'should_block' => ('block' === $policy),
			'message'      => $message
		);
	}
}
