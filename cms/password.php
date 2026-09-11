<?php 
/**********************************/
/* Pika CMS						  */ 
/* (C) 2011 Pika Software, LLC.   */
/* http://pikasoftware.com        */
/**********************************/

require_once ('pika-danio.php'); 
pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}
require_once('pikaTempLib.php');
require_once('pikaUser.php');
require_once('app/lib/plPasswordBreach.php');
if (PHP_VERSION_ID >= 50303)
{
	require_once('password_hash_compat.php');
}

$main_html = $html = array();

$settings = pikaSettings::getInstance();
$base_url = $settings['base_url'];
/*	Neither policy row has to exist. A new installation has no settings row
	for either of them until somebody saves the System Settings screen.
*/
$html['pass_min_length'] = $pass_min_length =
	isset($settings['pass_min_length']) ? $settings['pass_min_length'] : '';
$html['flags'] = '';

$action = pl_grab_post('action');

/*	Changing a password is the first thing an attacker on a borrowed
	session does, because it locks the account holder out. Ask for the
	current password again before the change takes effect.
	
	The challenge form deliberately does not carry password fields
	forward, so the POST that comes back out of it has an action but no
	passwords. Redirect instead of letting it fall through: without this
	the handler would run against an empty body, answer "New password
	cannot be blank", and leave the user in a loop with no way out.
*/
$was_reauth_post = isset($_POST['_reauth_scope']) && 'password_change' === $_POST['_reauth_scope'];

if ('update' == $action || $was_reauth_post)
{
	pl_reauth_required('password_change');
}

if ($was_reauth_post)
{
	header("Location: {$base_url}/password.php?reauth=1", true, 303);
	exit();
}

if ('1' === pl_grab_get('reauth'))
{
	$html['flags'] .= pikaTempLib::plugin('success_flag', 'success_flag',
		'Identity verified &mdash; enter your new password to finish.');
}

/*	Say why every other page keeps sending them here. pika-danio.php appends
	?must_change=1 when it redirects, but the flag on the row is what decides,
	so check both: a user who reaches this page by clicking Change Password
	still needs to be told.
*/
require_once('app/lib/pikaPasswordChange.php');

if (pl_password_change_required($auth_row['user_id']) || pl_grab_get('must_change') === '1')
{
	$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',
		'You must set a new password before you can continue. Every other '
		. 'page will send you back here until you have.');
}
$menu_pass_strength = array('' => 'None - No Strength Requirement',
							'0' => 'None - No Strength Requirement',
							'1' => '(1) Light',
							'2' => '(2) Light',
							'3' => '(3) Moderate',
							'4' => '(4) Strong');
$menu_pass_length = array(	'6' => '6',
							'7' => '7',
							'8' => '8',
							'9' => '9',
							'10' => '10');
$menu_pass_method = array(	'1' => "Lowercase Letters &amp Numbers",
							'2' => "All Letters, Numbers",
							'3' => "All Characters");
$html['p_len'] = '10';
$html['p_method'] = '1';
$html['pass_min_strength_label'] = $pass_min_strength_label = pl_array_lookup(
	isset($settings['pass_min_strength']) ? $settings['pass_min_strength'] : '',
	$menu_pass_strength);
$html['pass_min_length_label'] = $pass_min_length_label = "None - No Length Requirement";
if($pass_min_length)
{
	$html['pass_min_length_label'] = $pass_min_length_label = "({$pass_min_length}) Characters";
}


if($action == 'update')
{
	$oldpass = pl_grab_post('oldpass');
	$newpass1 = pl_grab_post('newpass1');
	$newpass2 = pl_grab_post('newpass2');
	
	$user = new pikaUser($auth_row['user_id']);
	$is_authorized = true;
	if(strlen($newpass1) < 1)
	{
		$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',"Error: New password cannot be blank");
		$is_authorized = false;
	}
	elseif ((md5($oldpass) != $user->password) && !(password_verify($oldpass, $user->password)))
	{
		$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',"Error: Old Password incorrect");
		$is_authorized = false;
	}
	else 
	{
		/*	Both settings hold a menu code, and both were compared against a
			value the code produces as a number. The System Settings screen
			writes a code, but the settings table is a label/value pair that a
			hand-written UPDATE, or a restored row from an older schema, can
			leave holding the display label instead - 'Strong', or
			'8 or More'. PHP 8 compares an integer against a string that is
			not numeric as a string, so 4 < 'Strong' is true and no password
			the user can type will ever satisfy the form. There is no error to
			read on that screen either, only "does not meet strength
			requirement" over and over.
			
			Casting makes a value that is not a number mean 0, which these two
			settings already spell as "no requirement".
		*/
		$min_strength = (int) (isset($settings['pass_min_strength']) ? $settings['pass_min_strength'] : 0);
		$min_length = (int) (isset($settings['pass_min_length']) ? $settings['pass_min_length'] : 0);
		
		if($min_strength > 0 && pikaUser::passStrength($newpass1) < $min_strength)
		{
			$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',"Error: New password does not meet strength requirement ({$pass_min_strength_label})");
			$is_authorized = false;
		}
		if($min_length > 0 && strlen($newpass1) < $min_length)
		{
			$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',"Error: New password does not meet length requirement ({$pass_min_length})");
			$is_authorized = false;
		}
		if($newpass1 != $newpass2){
			$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',"Error: New password(s) entries don't match");
			$is_authorized = false;
		}
		/*	Last of the checks, because it is the only one that costs a
			network round trip, and there is no point paying for it on a
			password the rules above have already refused.
			
			Does nothing at all unless an administrator has switched it on;
			see cms/app/lib/plPasswordBreach.php.
		*/
		if($is_authorized)
		{
			$breach = pl_password_breach_check($newpass1);
			
			if('compromised' === $breach['verdict'])
			{
				$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',
					pl_clean_html($breach['message']));
				
				if($breach['should_block'])
				{
					$is_authorized = false;
				}
				
				pl_audit('password.breach_check_hit', 'user', $auth_row['user_id'],
					array('count' => $breach['count'],
						'policy' => $breach['policy'],
						'blocked' => $breach['should_block'] ? 1 : 0));
			}
			elseif('unreachable' === $breach['verdict'])
			{
				pl_audit('password.breach_check_unreachable', 'user', $auth_row['user_id']);
			}
		}
	}
	
	if($is_authorized)
	{
		// password_hash, not md5. pikaAuthDb verifies with password_verify and
		// only falls back to md5 for rows that predate the bcrypt migration;
		// writing md5 here would downgrade an already-bcrypt hash on every
		// self-service password change.
		$user->password = password_hash($newpass1, PASSWORD_DEFAULT);
		$user->save();	
		/*	Clear the forced-change flag. The account holder has now picked
			a password nobody else has seen, which is the whole point of the
			flag. Written with its own statement rather than through
			pikaUser, so an installation without add_must_change_password.sql
			applied keeps working.
		*/
		pl_password_change_set($auth_row['user_id'], false);
		pl_audit('password.self_change', 'user', $auth_row['user_id']);
		
		/*	A password change has to end the sessions the old password opened,
			or a stolen session cookie keeps working after the account holder
			has done the one thing they are told to do about it. This session
			stays signed in; every other one is returned to the login form on
			its next request.
		*/
		$ended = pl_user_sessions_invalidate_others($auth_row['user_id'], pl_csrf_session_id());
		
		if ($ended > 0)
		{
			pl_audit('password.self_change_invalidated_sessions', 'user', $auth_row['user_id'], array(
				'sessions_ended' => $ended,
			));
			$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',"Your other sessions have been signed out ({$ended})");
		}
		$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',"Password updated successfully");
	}
	else 
	{
		pl_audit('password.self_change_failed', 'user', $auth_row['user_id']);
		$html['flags'] .= pikaTempLib::plugin('red_flag','red_flag',"Errors detected - Password not updated");
	}
}


$template = new pikaTempLib('subtemplates/password.html',$html);
$template->addMenu('p_len',$menu_pass_length);
$template->addMenu('p_method',$menu_pass_method);
$main_html['content'] = $template->draw();
$main_html['page_title'] = $page_title = 'Change Password';
$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> 
					&gt; {$page_title}";


$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);
