<?php

/***************************************/
/* Pika CMS (C) 2019 Pika Software LLC */
/* https://pikasoftware.com            */
/***************************************/

/*	The two account-form controls that decide how a user authenticates.
	
	They live here rather than in system-users.php because two pages render
	that form -- the desktop page and cms/m/system-users_mobile.php -- and a
	copy in each is a copy that can fall behind. The mobile page rendering an
	older version of these controls would show an administrator a sign-in
	method that is not the one in the database.
*/

require_once(dirname(__FILE__) . '/pikaCrypto.php');
require_once(dirname(__FILE__) . '/pikaSsoOidc.php');


if (!function_exists('pl_mfa_admin_control'))
{
	/*	Build the MFA control for one user account.

		The public build never lets an administrator see or create a shared
		secret. The admin only turns the requirement on; the account holder
		then enrols an authenticator on enroll_mfa.php the next time they
		sign in (see pl_mfa_enroll_gate() in cms/app/lib/pikaMfaEnroll.php).
		"Reset" keeps the requirement and drops the enrolled device, so the
		same page asks them to enrol again.

		Returns '' on a database that has not had cms/app/sql/upgrades/add_totp.sql
		applied yet, which leaves the form exactly as it was before MFA.
	*/
	function pl_mfa_admin_control($values)
	{
		if (!pl_totp_schema_ready())
		{
			return '';
		}
	
		$flag = isset($values['totp_enabled']) ? (string) $values['totp_enabled'] : '0';
	
		// 2 is the "Reset" request, not a stored state. If one was written to
		// the column anyway, it means the requirement is on.
		if ('2' === $flag)
		{
			$flag = '1';
		}
	
		$secret = isset($values['totp_secret']) ? (string) $values['totp_secret'] : '';
		$enrolled = (strlen($secret) > 0 && false !== pl_totp_decrypt($secret));
	
		if ('1' !== $flag)
		{
			$status = 'Off. This account signs in with a password only.';
		}
	
		elseif ($enrolled)
		{
			$status = 'On. An authenticator is enrolled.';
		}
	
		else
		{
			$status = 'On. The next sign-in asks this user to enrol an authenticator.';
		}
	
		$options = pikaMenu::getMenu('totp_enabled');
	
		if (!is_array($options) || 0 === count($options))
		{
			$options = array('1' => 'Yes', '0' => 'No');
		}
	
		// Resetting a device that does not exist would do nothing, so only
		// offer it once there is one to drop.
		if (!$enrolled)
		{
			unset($options['2']);
			unset($options[2]);
		}
	
		/*	The label is part of the returned markup so that a database
			without add_totp.sql shows no orphaned caption.
		*/
		$html = 'Multi-Factor Authentication:<br/>'
				. '<select name="totp_enabled" id="totp_enabled">';
	
		foreach ($options as $value => $label)
		{
			$selected = ((string) $value === $flag) ? ' selected="selected"' : '';
			$html .= '<option value="' . pl_html_escape($value) . '"' . $selected . '>'
					. pl_html_escape_label($label) . '</option>';
		}
	
		$html .= '</select><br/><em>' . pl_html_escape($status) . '</em>';
	
		return $html;
	}
}


if (!function_exists('pl_sso_admin_control'))
{
	/*	Build the single sign-on control for one user account.

		Two fields: which method signs this account in, and the provider's
		subject identifier for it. The subject is the stable, opaque id the
		provider puts in the `sub` claim -- not an email address, which
		providers do reassign -- so it is the only thing worth matching on.

		It is shown in the clear on purpose. It is not a secret: it identifies
		an account at the provider but grants nothing, and an administrator
		fixing a mis-bound account has to be able to read what is stored.

		Returns '' on a database that has not had
		cms/app/sql/upgrades/add_sso.sql applied, which leaves the form exactly
		as it was before SSO.
	*/
	function pl_sso_admin_control($values)
	{
		if (!pl_sso_schema_ready())
		{
			return '';
		}
	
		$method = isset($values['auth_method']) ? (string) $values['auth_method'] : 'password';
	
		if ('sso' !== $method)
		{
			$method = 'password';
		}
	
		$subject = isset($values['sso_subject']) ? (string) $values['sso_subject'] : '';
	
		$options = array(
			'password' => 'Password (and MFA, if set up)',
			'sso'      => 'Single sign-on'
		);
	
		$html = 'Sign-in Method:<br/>'
				. '<select name="auth_method" id="auth_method">';
	
		foreach ($options as $value => $label)
		{
			$selected = ($value === $method) ? ' selected="selected"' : '';
			$html .= '<option value="' . pl_html_escape($value) . '"' . $selected . '>'
					. pl_html_escape_label($label) . '</option>';
		}
	
		$html .= '</select><br/>';
	
		$html .= 'Identity Provider Subject:<br/>'
				. '<input type="text" name="sso_subject" id="sso_subject" size="48" value="'
				. pl_html_escape($subject) . '"/><br/>';
	
		if ('sso' === $method && 0 === strlen($subject))
		{
			$status = 'Single sign-on is selected but no subject is stored. This account '
				. 'cannot sign in until the subject is filled in, or until it binds itself '
				. 'through the identity provider if automatic binding by email is on.';
		}
	
		elseif ('sso' === $method)
		{
			$status = 'This account signs in at the identity provider. The password form '
				. 'refuses it.';
		}
	
		elseif (strlen($subject) > 0)
		{
			$status = 'A subject is stored but the password form is what signs this account '
				. 'in. Switch the method above to use single sign-on.';
		}
	
		else
		{
			$status = 'Leave both fields alone unless this account signs in through your '
				. 'identity provider.';
		}
	
		$html .= '<em>' . pl_html_escape($status) . '</em>';
	
		return $html;
	}
}
