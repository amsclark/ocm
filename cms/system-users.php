<?php 

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/


require_once('pika-danio.php');

pika_init();

// Every POST to this handler must carry the per-session CSRF token.
// See pl_csrf_check() in cms/app/lib/pl.php for the framework.
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	pl_csrf_check();
}

require_once('pikaTempLib.php');
require_once('plFlexList.php');
require_once('pikaUser.php');
require_once('pikaUserSession.php');
require_once('pikaGroup.php');
require_once('app/lib/pikaCrypto.php');
require_once('app/lib/pikaSsoOidc.php');
require_once('app/lib/pikaUserAdminControls.php');

// Menus

$menu_pass_length = array(	'6' => '6',
							'7' => '7',
							'8' => '8',
							'9' => '9',
							'10' => '10');
$menu_pass_method = array(	'1' => "Lowercase Letters &amp Numbers",
							'2' => "All Letters, Numbers",
							'3' => "All Characters");

// Variables

$action = pl_grab_var('action');
$user_id = pl_grab_var('user_id');
$order = pl_grab_get('order');
$order_field = pl_grab_get('order_field');
$offset = pl_grab_get('offset');
$page_size = $_SESSION['paging'];

$filter = array();
$filter['enabled'] = $enabled = pl_grab_get('enabled');
$filter['last_name'] = $last_name = pl_grab_get('last_name');
$filter['first_name'] = $first_name = pl_grab_get('first_name');
$filter['attorney'] = $attorney = pl_grab_get('attorney');
$filter['firm'] = $firm = pl_grab_get('firm');
$filter['city'] = $city = pl_grab_get('city');
$filter['county'] = $county = pl_grab_get('county');
$filter['group_id'] = $group_id = pl_grab_get('group_id');

$timeout_value = date('U') - (3600 * 48000000);  // Replaces PL_AUTH_TIMEOUT constant
$main_html = array();
$a = array();

$menu_enabled = array('0' => 'Disabled', '1' => 'Enabled');

$base_url = pl_settings_get('base_url');



if (!pika_authorize('users', $a))
{
	$main_html['page_title'] = 'User Accounts';
	$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt; 
						<a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
						User Accounts";
	$main_html['content'] = 'Access denied';
	
	$default_template = new pikaTempLib('templates/default.html', $main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}

$result = pikaGroup::getGroupsDB();
$groups = array();
while ($row = DBResult::fetchRow($result)) {
	$groups[$row['group_id']] = $row['group_id'];
}

switch ($action)
{
	case 'edit':
	
		if ($user_id)
		{
			$user = new pikaUser($user_id);
			$a = $user->getValues();
			unset($a['password']);
			$a['mfa_control'] = pl_mfa_admin_control($a);
			$a['sso_control'] = pl_sso_admin_control($a);
			/*	The shared secret and the replay counter never go to a
				browser. The form carries the requirement flag only.
			*/
			unset($a['totp_secret']);
			unset($a['totp_last_used']);
		}
		
		else
		{
			$a = array();
			$a['mfa_control'] = pl_mfa_admin_control($a);
			$a['sso_control'] = pl_sso_admin_control($a);
		}
		
		$a['p_len'] = '10';
		$a['p_method'] = '1';
		
		$result = pikaUserSession::getSessions(array('user_id' => $user_id),$row_count,'last_updated','DESC',0,1);
	 	$a['last_addr'] = "Never logged in";
	 	$a['last_active'] = "Never logged in";
	 	
		if(DBResult::numRows($result) == 1)
		{
	 		$row = DBResult::fetchRow($result);
			$a['last_addr'] = $row['ip_address'];
			$a['last_active'] = date('n/d/Y g:i A', $row['last_updated']);
		}
		
		$template = new pikaTempLib('subtemplates/system-users.html', $a, 'edit_user');
		$template->addMenu('groups',$groups);
		$template->addMenu('p_len',$menu_pass_length);
		$template->addMenu('p_method',$menu_pass_method);
		$main_html['content'] = $template->draw();
		$name = pikaTempLib::plugin('text_name','name',$a,array(),array("nomiddle","noextra"));
		$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
							 <a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
							 <a href=\"{$base_url}/system-users.php\">User Accounts</a> &gt;
							 {$name}";

		break;
		
	case 'update':
		
		$a['username'] = pl_grab_post('username');
		$password = pl_grab_post('password');
		if(strlen($password) > 0) {
			// bcrypt, not md5. Writing md5 here would downgrade an
			// already-bcrypt hash every time an admin sets a password.
			$a['password'] = password_hash($password, PASSWORD_DEFAULT);
		}
		$a['first_name'] = pl_grab_post('first_name');
		$a['middle_name'] = pl_grab_post('middle_name');
		$a['last_name'] = pl_grab_post('last_name');
		$a['extra_name'] = pl_grab_post('extra_name');
		$a['enabled'] = pl_grab_post('enabled');
		$a['group_id'] = pl_grab_post('group_id');
		$a['description'] = pl_grab_post('description');
		$a['email'] = pl_grab_post('email');
		$a['attorney'] = pl_grab_post('attorney');
		$a['atty_id'] = pl_grab_post('atty_id');
		$a['firm'] = pl_grab_post('firm');
		$a['address'] = pl_grab_post('address');
		$a['address2'] = pl_grab_post('address2');
		$a['city'] = pl_grab_post('city');
		$a['state'] = pl_grab_post('state');
		$a['zip'] = pl_grab_post('zip');
		$a['county'] = pl_grab_post('county');
		$a['phone_notes'] = pl_grab_post('phone_notes');
		$a['languages'] = pl_grab_post('languages');
		$a['practice_areas'] = pl_grab_post('practice_areas');
		$a['notes'] = pl_grab_post('notes');
		// These next two fields were added for the third-party HUD module.
        $a['emp_start_date'] = pl_grab_post('emp_start_date');
        $a['emp_end_date'] = pl_grab_post('emp_end_date');		
		
		$user = new pikaUser($user_id);
		// Capture the prior state of the security-relevant fields so the
		// audit log carries a focused diff rather than the whole row.
		$prev_group   = $user->group_id;
		$prev_enabled = $user->enabled;
		/*	getValue() rather than isset($user->totp_enabled): plBase has a
			__get() but no __isset(), so isset() on any column is always
			false and the prior value would read as 0 for every account.
			A column that is absent or NULL counts as off.
		*/
		$prev_mfa     = (string) $user->getValue('totp_enabled');
		if ('' === $prev_mfa)
		{
			$prev_mfa = '0';
		}
		$prev_method  = (string) $user->getValue('auth_method');
		if ('sso' !== $prev_method)
		{
			$prev_method = 'password';
		}
		$prev_subject = (string) $user->getValue('sso_subject');
		$is_create    = !is_numeric($user_id) || strlen($user_id) === 0;
		$user->setValues($a);
		$user->save();
		
		$target_user_id  = $user->user_id;
		$target_username = $user->username;
		
		if ($is_create)
		{
			pl_audit('user.create', 'user', $target_user_id, array(
				'username' => $target_username,
				'group_id' => $a['group_id'],
				'enabled'  => $a['enabled'],
			));
		}
		
		else
		{
			pl_audit('user.update', 'user', $target_user_id, array(
				'username' => $target_username,
			));
			if ($prev_group !== $a['group_id'])
			{
				pl_audit('user.group_change', 'user', $target_user_id, array(
					'username' => $target_username,
					'old'      => $prev_group,
					'new'      => $a['group_id'],
				));
			}
			if ($prev_enabled !== $a['enabled'])
			{
				$evt = ($a['enabled']) ? 'user.enable' : 'user.disable';
				pl_audit($evt, 'user', $target_user_id, array('username' => $target_username));
			}
			if (strlen($password) > 0)
			{
				// An admin set this user's password; self-service changes
				// land in password.php as password.self_change.
				pl_audit('user.password_admin_reset', 'user', $target_user_id, array('username' => $target_username));
			}
		}
		
		/*	MFA. This form carries the requirement flag and a reset
			request, never a secret: the secret is minted by the account
			holder on enroll_mfa.php. The columns are written with their
			own statement rather than through pikaUser so that a database
			without add_totp.sql applied keeps working, and so that a
			posted totp_secret cannot reach the table.
		*/
		if (pl_totp_schema_ready() && isset($_POST['totp_enabled']))
		{
			$posted_mfa = (string) pl_grab_post('totp_enabled');
			
			try
			{
				if ('2' === $posted_mfa)
				{
					// Keep the requirement, drop the enrolled device.
					DB::preparedQuery(
						"UPDATE users SET totp_enabled = 1, totp_secret = '', totp_last_used = NULL WHERE user_id = ? LIMIT 1",
						array($target_user_id)
					);
					pl_audit('user.mfa_reset', 'user', $target_user_id, array(
						'username' => $target_username,
					));
				}
				
				else
				{
					$new_mfa = ('1' === $posted_mfa) ? '1' : '0';
					DB::preparedQuery(
						"UPDATE users SET totp_enabled = ? WHERE user_id = ? LIMIT 1",
						array($new_mfa, $target_user_id)
					);
					
					if ($new_mfa !== $prev_mfa && !($is_create && '0' === $new_mfa))
					{
						$evt = ('1' === $new_mfa) ? 'user.mfa_enabled' : 'user.mfa_disabled';
						pl_audit($evt, 'user', $target_user_id, array(
							'username' => $target_username,
						));
					}
				}
			}
			
			/*	preparedQuery() throws on the legacy mysql_connect driver.
				Leave the flag alone rather than fall back to a built
				string; MFA needs PHP 5.5+ anyway for password_verify().
			*/
			catch (Exception $e)
			{
				error_log('system-users.php: could not write the MFA flag: ' . $e->getMessage());
			}
		}
		
		/*	Single sign-on. Written with its own statement for the same two
			reasons the MFA flag is: a database without add_sso.sql applied
			keeps working, and the columns that decide how an account
			authenticates are not reachable through pikaUser::setValues()
			from a posted field name.
		*/
		if (pl_sso_schema_ready() && isset($_POST['auth_method']))
		{
			$posted_method  = ('sso' === (string) pl_grab_post('auth_method')) ? 'sso' : 'password';
			$posted_subject = trim((string) pl_grab_post('sso_subject'));
			
			try
			{
				/*	Two accounts with the same subject is a state neither
					account can sign in from: pikaAuthSso refuses an
					ambiguous subject rather than guessing. Refusing the
					write here means the administrator finds out now, on the
					form, instead of when the user cannot sign in.
				*/
				$collision = false;
				
				if (strlen($posted_subject) > 0)
				{
					$rs = DB::preparedQuery(
						'SELECT user_id FROM users WHERE sso_subject = ? AND user_id <> ? LIMIT 1',
						array($posted_subject, $target_user_id)
					);
					$collision = ($rs && DBResult::numRows($rs) == 1);
				}
				
				if ($collision)
				{
					pl_audit('user.sso_subject_rejected', 'user', $target_user_id, array(
						'username' => $target_username,
						'reason'   => 'duplicate_sso_subject',
					));
					error_log('system-users.php: refused a duplicate sso_subject for user '
						. $target_user_id);
				}
				
				else
				{
					$new_subject = (strlen($posted_subject) > 0) ? $posted_subject : null;
					
					DB::preparedQuery(
						'UPDATE users SET auth_method = ?, sso_subject = ? WHERE user_id = ? LIMIT 1',
						array($posted_method, $new_subject, $target_user_id)
					);
					
					/*	An account moved to single sign-on keeps no password.
						Leaving the hash in place leaves a second way in that
						nobody is watching, and password expiry no longer
						means anything for an account that does not sign in
						with one. This mirrors what pikaAuthSso::autobind()
						does when an account binds itself.
					*/
					if ('sso' === $posted_method)
					{
						DB::preparedQuery(
							"UPDATE users SET password = '', password_expire = 0 WHERE user_id = ? LIMIT 1",
							array($target_user_id)
						);
					}
					
					if ($posted_method !== $prev_method)
					{
						pl_audit('user.auth_method_change', 'user', $target_user_id, array(
							'username' => $target_username,
							'old'      => $prev_method,
							'new'      => $posted_method,
						));
					}
					
					if ((string) $new_subject !== $prev_subject)
					{
						/*	The values themselves, not just that something
							changed: a subject is what decides which identity
							the account answers to, and an operator reading
							the log afterwards needs to see what it was moved
							from and to.
						*/
						pl_audit('user.sso_subject_change', 'user', $target_user_id, array(
							'username' => $target_username,
							'old'      => $prev_subject,
							'new'      => (string) $new_subject,
						));
					}
				}
			}
			
			catch (Exception $e)
			{
				error_log('system-users.php: could not write the SSO fields: ' . $e->getMessage());
			}
		}
		
		header("Location:{$base_url}/system-users.php");
		break;

	default:
		
		
		
		$user_list = new plFlexList();
		$user_list->template_file = 'subtemplates/system-users.html';
		$user_list->column_names = array('name','enabled','description','email','username','user_id','last_active');
		$user_list->table_url = "{$base_url}/system-users.php";
		$user_list->get_url = "enabled={$enabled}&last_name={$last_name}&attorney={$attorney}&firm={$firm}&city={$city}&county={$county}&group_id={$group_id}&";
		$user_list->order_field = $order_field;
		$user_list->order = $order;
		$user_list->records_per_page = $page_size;
		$user_list->page_offset = $offset;
		
		$row_count = 0;
		$result = pikaUser::getUsers($filter,$row_count,$order_field,$order,$offset,$page_size);
		
		while ($row = DBResult::fetchRow($result))
		{
			$r = array();
			$r['user_id'] = $row['user_id'];
			$name = pikaTempLib::plugin('text_name','name',$row,array(),array("order=last"));
			$r['name'] = $name;
			$r['enabled'] = pl_array_lookup($row['enabled'],$menu_enabled);
			if (!$row['enabled']){
				$r['enabled'] = "<em><font color=\"red\">" . $r['enabled'] . "</font></em>";
			} else {$r['enabled'] = "<font color=\"green\">" . $r['enabled'] . "</font>";}
			$r['description'] = $row["description"];
			$r['email'] = '<a href=mailto:' . $row["email"] . '>' . $row["email"] . '</a>';
			$r['username'] = $row["username"];
			
			
			$r['last_active'] = "Never logged in";
			if(strlen($row['last_active']) > 0)
			{
				$r['last_active'] = date('n/d/Y g:i A',strtotime($row['last_active']));
			}
			$user_list->addHtmlRow($r);
		}
		
		$user_list->total_records = $row_count;
		
		$a['enabled'] = $enabled;
		$a['last_name'] = $last_name;
		$a['attorney'] = $attorney;
		$a['group_id'] = $group_id;
		$a['firm'] = $firm;
		$a['city'] = $city;
		$a['county'] = $county;
		$a['order_field'] = $order_field;
		$a['order'] = $order;
		$a['user_list'] = $user_list->draw();
		$a['row_count'] = $row_count;

		$template = new pikaTempLib('subtemplates/system-users.html',$a,'user_list');
		$template->addMenu('groups',$groups);
		$template->addMenu('enabled',$menu_enabled);
		$main_html['content'] = $template->draw();
				
		$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
							 <a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
							 User Accounts";

		break;
}







$main_html['page_title'] = 'User Accounts';
$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();

pika_exit($buffer);

?>
