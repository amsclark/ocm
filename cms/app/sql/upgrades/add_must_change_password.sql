/*	Forced password change.
	
	users.must_change_password marks an account whose current password was
	not chosen by the person using it. Two things set it: the container
	entrypoint, when it generates the first password for the bootstrap
	account and prints it to the container log, and system-users.php, when
	an administrator sets somebody else's password. Until the account holder
	picks their own, that password is known to somebody who is not
	accountable for what is done with it.
	
	While the flag is set, every page except password.php, enroll_mfa.php
	and logout.php sends the user back to password.php. See
	cms/app/lib/pikaPasswordChange.php.
	
	Existing accounts default to 0, so applying this changes nothing for
	anybody already signed in.
	
	One clause per statement. MariaDB skips the remaining clauses of a
	multi-clause "ALTER ... ADD COLUMN IF NOT EXISTS" once any single clause
	is a no-op, so a re-run would silently leave later columns unadded. This
	file adds one column today; the shape is kept so that adding a second
	one later does not reintroduce that bug.
*/

ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `must_change_password` TINYINT(1) NOT NULL DEFAULT 0;
