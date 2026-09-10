<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

/*	pikaCrypto.php -- the TOTP second factor, and the encryption that keeps
	its shared secrets readable only to this application.
	
	Two separate jobs live here because they are useless apart.
	
	1. Encryption at rest. users.totp_secret holds the shared secret that
	   generates a user's six-digit codes. In cleartext, one leaked database
	   dump hands the reader a working second factor for every account in the
	   organisation, forever, and nobody can tell it happened. The stored
	   format is
	   
	       "enc:" . base64( nonce . sodium_crypto_secretbox(secret, nonce, key) )
	   
	   The "enc:" marker says "this row is already encrypted". A cleartext
	   base32 secret can never start with it, because the base32 alphabet is
	   [A-Z2-7], so the test is unambiguous.
	   
	   The 32-byte key is read from the FILE-BASED cms-custom/config/settings.php,
	   under the label totp_encryption_key, base64-encoded. It must not go in
	   the settings table: a key stored beside the ciphertext it protects means
	   a leaked dump decrypts itself, which is the whole thing this is meant to
	   stop. Two guards keep it out of the table -- pl_settings_save() unsets
	   the label before writing, and pl_settings_template_blocked() refuses to
	   resolve it as a template tag.
	   
	   Generate one with:
	   
	       php -r 'echo base64_encode(random_bytes(32)), "\n";'
	   
	   The container entrypoint does this on first start and writes the key
	   into the generated settings.php, so a `docker compose up` deployment
	   needs no manual step. Keep a copy: without the key, every enrolled
	   user has to enrol again.
	
	2. The RFC 6238 verifier. There is no composer autoloader in this
	   repository, so the code that checks a submitted code is written out
	   here rather than pulled from a library. It is a HMAC-SHA1 of the
	   30-second counter, truncated the way RFC 4226 section 5.3 specifies:
	   about twenty lines, and every authenticator app implements the same
	   thing.
	
	Failure is explicit everywhere. A missing or malformed key returns false
	and writes to the error log, and the login path treats that as MFA
	failing closed -- an enrolled user cannot log in without their second
	factor merely because the key went missing.
	
	libsodium ships with PHP 7.2 and later and is compiled into the container
	image, so there are no function_exists() guards around it.
	*/


if (!function_exists('pl_totp_encryption_key'))
{
	/**
	 * The raw 32-byte secretbox key, or null when it is not configured.
	 *
	 * Decoded on every call and cached for the request. A malformed key
	 * returns null rather than a truncated one, so callers fail closed
	 * instead of encrypting with half a key.
	 *
	 * @return string|null
	 */
	function pl_totp_encryption_key()
	{
		static $cached_key = null;
		static $cached_resolved = false;
		
		if ($cached_resolved)
		{
			return $cached_key;
		}
		
		$cached_resolved = true;
		
		if (!function_exists('pl_settings_get'))
		{
			return $cached_key;
		}
		
		$b64 = pl_settings_get('totp_encryption_key');
		
		if (!is_string($b64) || 0 === strlen($b64))
		{
			error_log('pikaCrypto: totp_encryption_key is missing from '
				. 'cms-custom/config/settings.php, so TOTP secrets cannot be '
				. 'read or written. Generate one with: '
				. 'php -r \'echo base64_encode(random_bytes(32));\'');
			
			return $cached_key;
		}
		
		$decoded = base64_decode($b64, true);
		
		if (false === $decoded || strlen($decoded) !== SODIUM_CRYPTO_SECRETBOX_KEYBYTES)
		{
			error_log('pikaCrypto: totp_encryption_key in settings.php is not a '
				. 'valid base64-encoded ' . SODIUM_CRYPTO_SECRETBOX_KEYBYTES
				. '-byte key. Regenerate it with: '
				. 'php -r \'echo base64_encode(random_bytes(32));\'');
			
			return $cached_key;
		}
		
		$cached_key = $decoded;
		
		return $cached_key;
	}
}


if (!function_exists('pl_totp_schema_ready'))
{
	/**
	 * Whether this database has had add_totp.sql applied.
	 *
	 * The administration page asks before it renders an MFA control, so a
	 * deployment that has not run the upgrade shows the user form it always
	 * showed instead of an error page. Memoised for the request, and fails
	 * closed.
	 *
	 * @return bool
	 */
	function pl_totp_schema_ready()
	{
		static $ready = null;
		
		if (!is_null($ready))
		{
			return $ready;
		}
		
		$ready = false;
		
		try
		{
			$columns = DB::query("SHOW COLUMNS FROM `users` LIKE 'totp_secret'");
			$menu = DB::query("SHOW TABLES LIKE 'menu_totp_enabled'");
			
			$ready = ($columns && DBResult::numRows($columns) > 0
				&& $menu && DBResult::numRows($menu) > 0);
		}
		
		catch (Exception $e)
		{
			$ready = false;
		}
		
		return $ready;
	}
}


if (!function_exists('pl_totp_is_encrypted'))
{
	/**
	 * Whether a stored value is in the encrypted-at-rest format. A prefix
	 * test only; it does not try to decrypt.
	 *
	 * @param mixed $value
	 * @return bool
	 */
	function pl_totp_is_encrypted($value)
	{
		return is_string($value) && 0 === strncmp($value, 'enc:', 4);
	}
}


if (!function_exists('pl_totp_encrypt'))
{
	/**
	 * Encrypt a secret with the configured key. Returns the "enc:..."
	 * string, or false on any failure.
	 *
	 * A fresh nonce every call: reusing one under secretbox with the same
	 * key breaks the cipher. The nonce is prepended to the ciphertext and
	 * the pair base64-encoded so the result is safe in a varchar column.
	 *
	 * @param string $secret
	 * @return string|false
	 */
	function pl_totp_encrypt($secret)
	{
		if (!is_string($secret) || 0 === strlen($secret))
		{
			return false;
		}
		
		$key = pl_totp_encryption_key();
		
		if (is_null($key))
		{
			return false;
		}
		
		try
		{
			$nonce = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
			$cipher = sodium_crypto_secretbox($secret, $nonce, $key);
		}
		
		catch (Throwable $e)
		{
			error_log('pikaCrypto: pl_totp_encrypt failed: ' . $e->getMessage());
			
			return false;
		}
		
		return 'enc:' . base64_encode($nonce . $cipher);
	}
}


if (!function_exists('pl_totp_decrypt'))
{
	/**
	 * Decrypt an "enc:..." string. Returns the cleartext, or false on a
	 * missing key, a malformed payload or a failed authentication tag.
	 *
	 * A value with no "enc:" prefix is returned unchanged. That is the
	 * bridge for a row written by hand, or by an older deployment, before
	 * the key existed; the next enrolment rewrites it encrypted.
	 *
	 * @param string $value
	 * @return string|false
	 */
	function pl_totp_decrypt($value)
	{
		if (!is_string($value) || 0 === strlen($value))
		{
			return false;
		}
		
		if (!pl_totp_is_encrypted($value))
		{
			return $value;
		}
		
		$key = pl_totp_encryption_key();
		
		if (is_null($key))
		{
			return false;
		}
		
		$blob = base64_decode(substr($value, 4), true);
		
		if (false === $blob
			|| strlen($blob) < SODIUM_CRYPTO_SECRETBOX_NONCEBYTES + SODIUM_CRYPTO_SECRETBOX_MACBYTES)
		{
			error_log('pikaCrypto: pl_totp_decrypt got a malformed payload '
				. '(bad base64, or too short to hold a nonce and a tag).');
			
			return false;
		}
		
		$nonce = substr($blob, 0, SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
		$cipher = substr($blob, SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
		
		try
		{
			$plain = sodium_crypto_secretbox_open($cipher, $nonce, $key);
		}
		
		catch (Throwable $e)
		{
			error_log('pikaCrypto: pl_totp_decrypt threw: ' . $e->getMessage());
			
			return false;
		}
		
		if (false === $plain)
		{
			error_log('pikaCrypto: pl_totp_decrypt failed its authentication '
				. 'check. The key is wrong, the row was written with a '
				. 'different key, or the ciphertext was altered.');
			
			return false;
		}
		
		return $plain;
	}
}


// ── RFC 4648 base32, the alphabet every authenticator app expects ──────────

if (!function_exists('pl_totp_base32_encode'))
{
	/**
	 * Encode raw bytes as base32 with no padding, which is what the
	 * otpauth:// URI and every authenticator app want.
	 *
	 * @param string $bytes
	 * @return string
	 */
	function pl_totp_base32_encode($bytes)
	{
		$alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
		$out = '';
		$buffer = 0;
		$bits = 0;
		$len = strlen($bytes);
		
		for ($i = 0; $i < $len; $i++)
		{
			$buffer = ($buffer << 8) | ord($bytes[$i]);
			$bits += 8;
			
			while ($bits >= 5)
			{
				$bits -= 5;
				$out .= $alphabet[($buffer >> $bits) & 31];
			}
		}
		
		if ($bits > 0)
		{
			$out .= $alphabet[($buffer << (5 - $bits)) & 31];
		}
		
		return $out;
	}
}


if (!function_exists('pl_totp_base32_decode'))
{
	/**
	 * Decode a base32 secret to raw bytes. Padding, spaces and lower case
	 * are all accepted, because users retype secrets by hand. Returns
	 * false when the string contains anything outside the alphabet, rather
	 * than quietly decoding part of it.
	 *
	 * @param string $b32
	 * @return string|false
	 */
	function pl_totp_base32_decode($b32)
	{
		if (!is_string($b32))
		{
			return false;
		}
		
		$alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
		$b32 = strtoupper(str_replace(array(' ', '-', '='), '', $b32));
		
		if (0 === strlen($b32))
		{
			return false;
		}
		
		$buffer = 0;
		$bits = 0;
		$out = '';
		$len = strlen($b32);
		
		for ($i = 0; $i < $len; $i++)
		{
			$pos = strpos($alphabet, $b32[$i]);
			
			if (false === $pos)
			{
				return false;
			}
			
			$buffer = ($buffer << 5) | $pos;
			$bits += 5;
			
			if ($bits >= 8)
			{
				$bits -= 8;
				$out .= chr(($buffer >> $bits) & 255);
			}
		}
		
		return $out;
	}
}


if (!function_exists('pl_totp_generate_secret'))
{
	/**
	 * A fresh 160-bit shared secret, base32-encoded: the length RFC 4226
	 * recommends and what authenticator apps are tested against.
	 *
	 * @return string
	 */
	function pl_totp_generate_secret()
	{
		return pl_totp_base32_encode(random_bytes(20));
	}
}


if (!function_exists('pl_totp_code_at'))
{
	/**
	 * The six-digit code for one 30-second window.
	 *
	 * HMAC-SHA1 of the counter as a 64-bit big-endian integer, truncated
	 * the way RFC 4226 section 5.3 specifies: the low four bits of the last
	 * byte pick an offset, four bytes are read from there, the top bit is
	 * masked off, and the remainder modulo 10^6 is the code.
	 *
	 * @param string $secret_raw Decoded secret bytes.
	 * @param int $counter Window index, i.e. floor(unixtime / 30).
	 * @return string Six digits, left-padded with zeros.
	 */
	function pl_totp_code_at($secret_raw, $counter)
	{
		// pack('N*', high, low) is the portable way to write an unsigned
		// 64-bit big-endian value; 'J' would depend on a 64-bit build.
		$binary = pack('N*', 0, (int) $counter);
		$hash = hash_hmac('sha1', $binary, $secret_raw, true);
		$offset = ord($hash[19]) & 0xf;
		
		$value = ((ord($hash[$offset]) & 0x7f) << 24)
			| ((ord($hash[$offset + 1]) & 0xff) << 16)
			| ((ord($hash[$offset + 2]) & 0xff) << 8)
			| (ord($hash[$offset + 3]) & 0xff);
		
		return str_pad((string) ($value % 1000000), 6, '0', STR_PAD_LEFT);
	}
}


if (!function_exists('pl_totp_verify_once'))
{
	/**
	 * Check a submitted code, and refuse anything that is not strictly
	 * newer than the last code this user authenticated with.
	 *
	 * A plain check accepts the same six digits for the whole window, so a
	 * code read over somebody's shoulder can be replayed into a second
	 * session before it expires. users.totp_last_used holds the window
	 * index of the last accepted code and nothing at or below it is
	 * accepted again.
	 *
	 * One window of tolerance either side of now, so a clock that is a few
	 * seconds out still works.
	 *
	 * This deliberately does NOT write the new index. The code is checked
	 * before the password on the login path, so burning it here would let
	 * somebody who can see the authenticator app, but does not know the
	 * password, walk the user's codes and lock them out one at a time. The
	 * caller records the burn with pl_totp_mark_used() once the whole
	 * authentication has succeeded.
	 *
	 * @param int $user_id Row whose totp_last_used bounds the check.
	 * @param string $secret Decrypted base32 secret.
	 * @param string $code Submitted code.
	 * @return int|false The window index that matched, or false.
	 * @see pl_totp_mark_used()
	 */
	function pl_totp_verify_once($user_id, $secret, $code)
	{
		$user_id = (int) $user_id;
		
		if ($user_id <= 0 || !is_string($secret) || '' === $secret)
		{
			return false;
		}
		
		if (!is_string($code))
		{
			return false;
		}
		
		/*	A cheap format check before the database read, so a garbage
			submission costs no query. pl_totp_verify_window() re-checks the
			same thing; it has to, because enrollment calls it directly.
		*/
		if (!preg_match('/^[0-9]{6}$/', str_replace(array(' ', '-'), '', trim($code))))
		{
			return false;
		}
		
		$last_used = null;
		
		try
		{
			$rs = DB::preparedQuery(
				'SELECT totp_last_used FROM users WHERE user_id = ? LIMIT 1',
				array($user_id)
			);
			
			if ($rs && 1 === DBResult::numRows($rs))
			{
				$r = DBResult::fetchRow($rs);
				
				if (isset($r['totp_last_used']) && '' !== (string) $r['totp_last_used'])
				{
					$last_used = (int) $r['totp_last_used'];
				}
			}
		}
		
		catch (Throwable $e)
		{
			/*	The column is missing because the upgrade has not been
				applied, or the database hiccupped. Carry on with no replay
				bound: the guard is an addition to the check, not the check
				itself, and MFA must keep working without it.
			*/
			$last_used = null;
		}
		
		return pl_totp_verify_window($secret, $code, $last_used);
	}
}


if (!function_exists('pl_totp_verify_window'))
{
	/**
	 * The window check itself, with no database read.
	 *
	 * pl_totp_verify_once() is the function the login path wants: it looks
	 * up users.totp_last_used and refuses a window that has already been
	 * spent. This one takes that bound as an argument, and accepts null for
	 * "no bound".
	 *
	 * Enrollment is the caller that needs the unbounded form. The secret it
	 * is confirming is brand new, so a totp_last_used left behind by an
	 * earlier enrollment on the same account bears no relation to it and
	 * would refuse every code the user typed -- with the enrollment gate in
	 * front of every page, that wedges the user out of the application
	 * entirely. Enrollment writes the bound itself once the code matches.
	 *
	 * One window of tolerance either side of now, so a clock a few seconds
	 * out still works.
	 *
	 * @param string $secret Decrypted base32 secret.
	 * @param string $code Submitted code.
	 * @param int|null $last_used Highest window already spent, or null.
	 * @return int|false The window index that matched, or false.
	 */
	function pl_totp_verify_window($secret, $code, $last_used = null)
	{
		if (!is_string($secret) || '' === $secret || !is_string($code))
		{
			return false;
		}
		
		// Users read the code off a phone, so tolerate the spaces some apps
		// display. Anything else is not a code.
		$code = str_replace(array(' ', '-'), '', trim($code));
		
		if (!preg_match('/^[0-9]{6}$/', $code))
		{
			return false;
		}
		
		$secret_raw = pl_totp_base32_decode($secret);
		
		if (false === $secret_raw || strlen($secret_raw) < 10)
		{
			return false;
		}
		
		$now_window = (int) floor(time() / 30);
		
		for ($offset = -1; $offset <= 1; $offset++)
		{
			$window = $now_window + $offset;
			
			if ($window <= 0)
			{
				continue;
			}
			
			if (!is_null($last_used) && $window <= $last_used)
			{
				continue;
			}
			
			if (hash_equals(pl_totp_code_at($secret_raw, $window), $code))
			{
				return $window;
			}
		}
		
		return false;
	}
}


if (!function_exists('pl_totp_mark_used'))
{
	/**
	 * Record the window index the user just authenticated with, closing it
	 * and every earlier one to replay.
	 *
	 * Best effort. A failure here must not fail a login that has otherwise
	 * succeeded; it only means the same code stays usable for the rest of
	 * its window.
	 *
	 * @param int $user_id
	 * @param int $window Index returned by pl_totp_verify_once().
	 * @return void
	 */
	function pl_totp_mark_used($user_id, $window)
	{
		$user_id = (int) $user_id;
		$window = (int) $window;
		
		if ($user_id <= 0 || $window <= 0)
		{
			return;
		}
		
		try
		{
			DB::preparedQuery(
				'UPDATE users SET totp_last_used = ? WHERE user_id = ? LIMIT 1',
				array($window, $user_id)
			);
		}
		
		catch (Throwable $e)
		{
			// See the docblock: a failure here is not a failed login.
		}
	}
}
