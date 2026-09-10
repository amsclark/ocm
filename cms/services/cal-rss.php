<?php

/*	Calendar RSS feed.
	
	This file used to define PL_DISABLE_SECURITY, which tells pika_init() to
	skip authenticate() altogether, and then read a user id off the query
	string. Anyone who could reach the URL - no cookie, no password, no
	account - got that user's next week of activities back, summary and notes
	included. On a legal aid installation those notes are client
	confidences. Measured on the test stack before this change: an
	unauthenticated GET of services/cal-rss.php?user_id=1 returned the feed.
	
	It now authenticates like every other page, and answers only for a
	calendar the caller may see - see pl_can_view_user_calendar() in
	cms/pika-danio.php. The <link rel="alternate"> that cal_day.php puts in
	its head still works, because a browser sends the session cookie with it.
	A feed reader that holds no session gets the login page instead; the
	iCal service under services/calendar.php is the one built for external
	clients, and it has always asked for credentials.
	
	The two statements are prepared now. The first one interpolated
	$safe_user_id, which was never assigned - the escaped copy is
	$clean_user_id - so it always searched for the empty string and the
	preferences it guards never loaded.
	
	The summary and the notes went into the XML raw. A '&' in a case note is
	not well-formed XML and ends the feed at that item; a '<' lets the note
	write its own markup. Both are escaped now.
*/

chdir("..");
require_once ('pika-danio.php');
pika_init();

$user_id = pl_grab_get('user_id');

/*	The feed is for one user. Anything that is not a user id - including the
	'mine' keyword the calendar pages accept - falls back to the caller's own
	calendar, which is what an unqualified request is asking for anyway.
*/
if (strlen((string) $user_id) < 1 || !ctype_digit((string) $user_id))
{
	$user_id = $auth_row['user_id'];
}

if (!pl_can_view_user_calendar($user_id))
{
	pl_log_error('calendar rss refused', 'user ' . $auth_row['user_id']
		. ' asked for user ' . $user_id);
	header('Content-Type: text/plain; charset=UTF-8');
	echo "You may not read that calendar.";
	exit();
}

$base_url = pl_settings_get('base_url');

if (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] == TRUE)
{
	$cal_url = "https://" . $_SERVER['HTTP_HOST'] . $base_url;
}

else
{
	$cal_url = "http://" . $_SERVER['HTTP_HOST'] . $base_url;
}

$sql = "SELECT user_id FROM users WHERE 1 AND enabled = 1 AND user_id = ? LIMIT 1;";
$result = DB::preparedQuery($sql,array($user_id));

if (DBResult::numRows($result) == 1)
{
	require_once ('pikaDefPrefs.php');
	pikaDefPrefs::getInstance()->initPrefs($user_id);
}

header("Content-Type: application/rss+xml; charset=UTF-8");
echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
echo "<rss version=\"2.0\">\n";
echo "\t<channel>\n";
echo "\t\t<title>Pika CMS Calendar</title>\n";
echo "\t\t<link>" . htmlspecialchars($cal_url . "/cal_day.php") . "</link>\n";
echo "\t\t<description>My calendar</description>\n";

$date = date('Y-m-d');
$interval = 7;

if (isset($_SESSION['def_rss_interval']) && is_numeric($_SESSION['def_rss_interval']))
{
	$interval = $_SESSION['def_rss_interval'];
}

$end_date = date('Y-m-d',time() + ($interval * 24 * 60 * 60));

$sql = "SELECT act_id, act_date, act_time, summary, notes
		FROM activities
		WHERE user_id = ? AND completed = 0 AND act_date >= ? AND act_date < ?
		LIMIT 200";

$result = DB::preparedQuery($sql,array($user_id,$date,$end_date))
	or die("query failed");

while ($row = DBResult::fetchRow($result))
{
	$act_date = pl_date_unmogrify($row['act_date']);
	$act_time = pl_time_unmogrify($row['act_time']);
	$title = htmlspecialchars("{$act_date} {$act_time} - " . (string) $row['summary']);
	$link = htmlspecialchars("{$cal_url}/activity.php?act_id={$row['act_id']}");
	$notes = htmlspecialchars((string) $row['notes']);
	echo "\t\t<item>\n";
	echo "\t\t\t<title>{$title}</title>\n";
	echo "\t\t\t<link>{$link}</link>\n";
	echo "\t\t\t<description>{$notes}</description>\n";
	echo "\t\t</item>\n";
}

echo "\t</channel>\n";
echo "</rss>";
