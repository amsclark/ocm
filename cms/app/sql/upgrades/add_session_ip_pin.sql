-- Session address pin.
--
-- Two changes, both needed before pikaAuth can compare addresses for real.
--
-- 1. user_sessions.ip_address is VARCHAR(15). That holds the longest IPv4
--    literal and nothing else. On a host reachable over IPv6 REMOTE_ADDR
--    arrives as something like 2001:db8:85a3::8a2e:370:7334 and MariaDB,
--    which is not in strict mode on most deployments, stores the first 15
--    characters of it without complaining. The next request compares the
--    stored prefix against the full address, the comparison fails, and the
--    user is treated as a hijacked session: back to the sign-in page, sign
--    in, bounced again. It looks like a broken login loop. 45 is the
--    conventional width for an IPv6 literal with an IPv4-mapped tail and a
--    zone index; audit_log.ip_address was created at 45 already.
--
-- 2. The session_ip_pin setting. Some offices sit behind an internet
--    connection whose public address does not hold still: a dual-WAN
--    firewall balancing across two carriers, a carrier-grade NAT that
--    re-homes the office every few minutes, a satellite link. Staff there
--    are signed out every time it moves, and nothing on their side can be
--    asked to stop moving, so the org has to be able to turn the address
--    half of the pin off.
--
--      'network'  compare the network the session was minted from: same
--                 /24 for IPv4, same /64 for IPv6. The default.
--      'off'      never compare addresses. The user-agent pin and both
--                 timeouts still apply.
--
-- Idempotent. One clause per ALTER on purpose: MariaDB can silently apply
-- none of the clauses in a multi-clause ALTER when one of them is already
-- satisfied.

ALTER TABLE `user_sessions`
	MODIFY COLUMN `ip_address` VARCHAR(45) DEFAULT NULL;

INSERT IGNORE INTO settings (label, value) VALUES ('session_ip_pin', 'network');
