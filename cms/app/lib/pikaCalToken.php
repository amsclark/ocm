<?php

/**********************************/
/* Pika CMS                       */
/* http://pikasoftware.com        */
/**********************************/

/*	The bearer token behind the iCal subscription URL.
	
	A calendar program cannot log in. It is handed a URL once and then polls
	it, unattended, for years. So the URL has to carry something that stands
	in for a session -- and what it used to carry was the account's own
	credentials.
	
	cms/ical-subscribe.php built the link as
	
		base64_encode(serialize(array($user->username, $user->password)))
	
	and $user->password is the stored hash. The page printed the account's
	bcrypt hash inside a URL and told the user to paste it into Outlook. From
	there it goes into the calendar client's configuration file on disk, into
	the browser history, into whatever the user pastes it into when the
	subscription stops working, and into the access log of every proxy in
	between. A hash is not a password, but it is exactly the input an offline
	attack runs against, and an account still carrying a pre-bcrypt md5 row is
	a few seconds of work.
	
	The link now carries a value that is nothing but a bearer token: 32 random
	bytes, hex encoded, stored in users.cal_token by add_ical_token.sql.
	
		* It says nothing about the password.
		* It can be revoked by clearing the column, with no password change
		  and no effect on anything else the account can do.
		* It grants exactly one thing: a read of that user's own appointments.
	
	What it does NOT do is make the calendar feed safe to hand out. Anyone
	holding the URL reads that user's calendar, which on a legal aid system
	names clients and hearings. It is a secret, and it is treated as one: it
	is compared with hash_equals(), it is never written to the audit log, and
	the subscription page is the only place it is shown.
	
	The old token path did not work at all, incidentally. It put the stored
	hash into PHP_AUTH_PW and handed it to pikaAuthDb, which compares a
	submitted password against the hash -- so the hash never matched itself
	and cms/services/calendar.php answered 401 to the very URL the
	subscription page produced. Closing the leak and making the feature work
	are the same change.
*/

require_once('pl.php');

/*	Whether this installation has the column.
	
	add_ical_token.sql is applied by docker/entrypoint.sh from APPLY_IN_ORDER,
	but a hand-built installation may not have run it. Every function here
	fails closed when the column is missing rather than letting a SELECT or an
	UPDATE naming an absent column take down the calendar service, and the
	subscription page offers only the direct link.
	
	Memoised for the request. SHOW COLUMNS is cheap but this is called on
	every calendar poll.
*/
function pl_cal_token_supported()
{
	static $supported = null;
	
	if (null !== $supported)
	{
		return $supported;
	}
	
	$supported = false;
	
	try
	{
		$supported = pl_mysql_column_exists('users','cal_token');
	}
	
	catch (Exception $e)
	{
		$supported = false;
	}
	
	return $supported;
}


/*	The token for $user_id, creating one on first use.
	
	Deliberately NOT rotated on every visit. Rotating would mean that opening
	the subscription page -- which a user may do just to re-read the
	instructions -- silently breaks the subscription already configured on
	their phone, with no error anywhere either of them would see. A user who
	needs a new token gets one by having the column cleared, which is a
	revocation and should look like one.
	
	Returns '' when the column is missing or the account does not exist, so
	the caller can leave the token link off the page instead of printing a
	broken one.
*/
function pl_cal_token_issue($user_id = null)
{
	if (!pl_cal_token_supported() || !is_numeric($user_id))
	{
		return '';
	}
	
	$user_id = (int) $user_id;
	
	$result = DB::preparedQuery('SELECT cal_token FROM users WHERE user_id = ? AND enabled = 1',
		array($user_id));
	
	if (!$result || DBResult::numRows($result) != 1)
	{
		return '';
	}
	
	$row = DBResult::fetchRow($result);
	$token = isset($row['cal_token']) ? (string) $row['cal_token'] : '';
	
	/*	A stored value of the wrong shape is replaced rather than used. The
		column is new, so the only way to get one is by hand, and a short or
		non-hex value is not a 256-bit secret whatever it looks like.
	*/
	if (64 === strlen($token) && preg_match('/^[0-9a-f]{64}$/', $token))
	{
		return $token;
	}
	
	$token = bin2hex(random_bytes(32));
	
	DB::preparedQuery('UPDATE users SET cal_token = ? WHERE user_id = ?',
		array($token,$user_id));
	
	pl_audit('ical.token_issued','user',$user_id);
	
	return $token;
}


/*	Verify a subscription token and return the row to run the feed as.
	
	Returns the user row joined to its group, in the shape pikaAuthHttp
	produced, or false. The caller answers 401 on false; there is no fallback
	to any other credential.
	
	$user_id travels in the URL alongside the token so the row can be fetched
	before the secret is compared, and the comparison can then be
	hash_equals(). Looking the token up in the WHERE clause instead would push
	the comparison into the database, where it is neither constant time nor
	something this code can reason about. A user id is not a secret -- staff
	see each other in the application -- and the token alone is what grants
	anything.
*/
function pl_cal_token_verify($user_id = null, $token = null)
{
	if (!pl_cal_token_supported())
	{
		return false;
	}
	
	$token = (string) $token;
	
	if (!is_numeric($user_id) || 64 !== strlen($token))
	{
		return false;
	}
	
	$user_id = (int) $user_id;
	
	$sql = "SELECT users.user_id, users.username, users.enabled, users.cal_token,
			users.group_id AS group_name, `groups`.*
			FROM users
			LEFT JOIN `groups` ON users.group_id = groups.group_id
			WHERE users.user_id = ?
			AND users.enabled = 1";
	$result = DB::preparedQuery($sql,array($user_id));
	
	if (!$result || DBResult::numRows($result) != 1)
	{
		pl_audit('ical.token_rejected','user',$user_id,array('reason' => 'no_such_account'));
		
		return false;
	}
	
	$row = DBResult::fetchRow($result);
	$stored = isset($row['cal_token']) ? (string) $row['cal_token'] : '';
	
	if (64 !== strlen($stored) || !hash_equals($stored,$token))
	{
		pl_audit('ical.token_rejected','user',$user_id,array('reason' => 'bad_token'));
		
		return false;
	}
	
	/*	Do not hand the secret on to the rest of the request. The feed builds
		its output out of this row and a stray %%[cal_token]%% tag in a
		per-organisation template would print it.
	*/
	unset($row['cal_token']);
	
	return $row;
}
