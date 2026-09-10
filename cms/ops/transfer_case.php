<?php

/***************************/
/* Pika CMS (C) 2011       */
/* Pika Software, LLC.     */
/* http://pikasoftware.com */
/***************************/

chdir('../');

require_once ('pika-danio.php');
pika_init();

/*	This handler reads its input with pl_grab_post() and the only thing that
	links to it is the POST form in subtemplates/transfer.html, which carries
	the per-session token. Refuse anything else.
	
	A GET used to run the whole transfer with no case_id: pikaCase built an
	empty new case, took an id for it out of the counters table, and offered
	that to a transfer option that was equally blank.
	
	See pl_csrf_check() in cms/app/lib/pl.php for the token framework.
*/
if (!isset($_SERVER['REQUEST_METHOD']) || $_SERVER['REQUEST_METHOD'] !== 'POST')
{
	header('HTTP/1.1 405 Method Not Allowed');
	header('Allow: POST');
	header('Content-Type: text/plain; charset=utf-8');
	echo "A case transfer must be submitted as a POST with a CSRF token.\n";
	exit();
}

pl_csrf_check();
require_once('pikaCase.php');
require_once('pikaMisc.php');
require_once('pikaSettings.php');

require_once('pikaTempLib.php');

// VARIABLES

$case_id = pl_grab_post('case_id');
$action = pl_grab_post('action');
$transfer_option_id = pl_grab_post('transfer_option_id');

$base_url = pl_settings_get('base_url');
$owner_name = pl_settings_get('owner_name');


// Menus

$staff_array = pikaMisc::fetchStaffArray();

function post_transfer($url = null,$data = null,$optional_headers = null)
{
	
	$params = array('http' => array(
					'method' => 'POST',
					'content' => $data
	));
	if ($optional_headers !== null) 
	{
		$params['http']['header'] = $optional_headers;
	}
	$ctx = stream_context_create($params);
	$fp = @fopen($url, 'rb', false, $ctx);
	if (!$fp) 
	{
		$msg = "Problem connecting to receiving server.  Please verify that the URL and Authentication credentials supplied are correct.\n<br/>URL: {$url}";
		throw new Exception($msg);
	}
	$response = @stream_get_contents($fp);
	if ($response === false) {
		throw new Exception("Problem reading data from stream at $url");
	}
	return $response;
}

/*	Build one packet for the receiving installation.
	
	Signed JSON when this side has a shared secret, because the receiving
	end reads a serialize() body with unserialize() only if its operator has
	explicitly turned that back on. The signature covers the action, the
	body and the timestamp together, so none of the three can be swapped out
	of a captured packet, and the receiver refuses a timestamp more than 300
	seconds from its own clock.
	
	No secret configured means the old serialize() body, so that a pair of
	installations can be upgraded one at a time. Configure
	peer_transfer_shared_secret on both ends and this stops happening.
*/
function build_transfer_packet($action,$row_data)
{
	$secret = pl_settings_get('peer_transfer_shared_secret');
	if (is_string($secret) && strlen($secret) > 0)
	{
		$json_payload = json_encode($row_data,JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
		if (false !== $json_payload)
		{
			$ts = (string) time();
			return array(	'action' => $action,
							'payload' => $json_payload,
							'format' => 'json',
							'ts' => $ts,
							'signature' => hash_hmac('sha256',$action . "\n" . $json_payload . "\n" . $ts,$secret),
							'_row_for_v5_checksum' => $row_data
			);
		}
	}
	
	return array(	'action' => $action,
					'payload' => serialize($row_data),
					'_row_for_v5_checksum' => $row_data
	);
}

function pika_transfer($data,$transfer_option_id)
{
	$response = false;
	
	require_once('pikaTransferOption.php');
	$tx = new pikaTransferOption($transfer_option_id);
	$user = $tx->user;
	$pass = $tx->password;
	$url = $tx->url;

	$auth = base64_encode($user.':'.$pass);
	$auth_header = 	"Content-type: application/x-www-form-urlencoded\r\n" .
					"Authorization: Basic {$auth}\r\n";
	
	/*	Pika CMS v5 receivers check this exact MD5 of the row and refuse the
		request without it, so it stays for interoperability. It is not an
		authenticity check: that is HTTP Basic, plus the HMAC signature that
		build_transfer_packet() adds. The row is taken from the packet
		rather than by unserializing the body back out of it.
	*/
	$data['checksum'] = md5(var_export($data['_row_for_v5_checksum'], true));
	unset($data['_row_for_v5_checksum']);
	
	$data = http_build_query($data);
	
	try {
		$response = post_transfer($url,$data,$auth_header);
		return $response;
	} 
	catch (Exception $e)
	{
		trigger_error($e->getMessage());
	}
	
}


function transfer_error($msg = null,$line = 0,$case_id = null)
{
	require_once('pikaSettings.php');
	$base_url = pl_settings_get('base_url');
	
	$main_html = array();
	$main_html['content'] = "There was a problem during the case transfer process.  <em>The case has not been transferred correctly.</em><br/>\n".
							"Message: {$msg}".
							"Line No: {$line}<br/>\n". 
							"<a href=\"{$base_url}/case.php?case_id={$case_id}\">Return to this case</a>";
	$main_html['page_title'] = 'Case Transfer';
	$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt; Case Transfer";
	$default_template = new pikaTempLib('templates/default.html',$main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}


// BEGIN MAIN CODE...

/*	Both ids have to name a record that is there.
	
	plBase reads a missing or non-numeric id as "this is a new record", so a
	request without them built an empty case and an empty transfer option
	instead of failing, and each one took a value out of the counters table
	on the way past.
*/
if (!is_numeric($case_id) || !is_numeric($transfer_option_id))
{
	transfer_error('Pick a case and a transfer destination.',__LINE__,null);
}

// ENFORCE PERMISSIONS
$case = new pikaCase($case_id);
$case_row = $case->getValues();
if (!pika_authorize('edit_case', $case_row))
{
	// set up template, then display page
	$main_html['content'] = "Access Denied - You do not have the necessary permissions to transfer this case.";
	$default_template = new pikaTempLib('templates/default.html',$main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}



// cases record.

unset($case_row['user_id']);
unset($case_row['cocounsel1']);
unset($case_row['cocounsel2']);
unset($case_row['intake_user_id']);

$client_id = $case_row['client_id'];
unset($case_row['client_id']);


$data = build_transfer_packet('newCase',$case_row);

$response = pika_transfer($data,$transfer_option_id);

$tx_case_id = $response;
if (!is_numeric($response))
{
	$msg = 'Action: newCase<br/>\nError: Unable to transfer case data.<br/>\nResponse: ' . pl_html_escape($response);
	transfer_error($msg,__LINE__,$case_id);
}

// contacts and conflicts.
$stack = array();
$result = $case->getContactsDb();
while ($contact_row = DBResult::fetchRow($result))
{
	$data = build_transfer_packet('newContact',$contact_row);
	
	$response = pika_transfer($data,$transfer_option_id);
	
	$tx_contact_id = $response;
	if (!is_numeric($response))
	{
		$msg = 'Action: newContact<br/>\nError: Unable to Add Case Contact.<br/>\nResponse: ' . pl_html_escape($response);
		transfer_error($msg,__LINE__,$case_id);
	}
	
	if ($contact_row['contact_id'] == $client_id) 
	{
		array_unshift($stack, array('0' => $tx_case_id, '1' => $tx_contact_id, '2' => $contact_row['relation_code']));
	}
	else 
	{
		array_push($stack, array('0' => $tx_case_id, '1' => $tx_contact_id, '2' => $contact_row['relation_code']));
	}
}

while (sizeof($stack) > 0) 
{
	$data = build_transfer_packet('addCaseContact',array_shift($stack));
	
	$response = pika_transfer($data,$transfer_option_id);
	if (!is_numeric($response))
	{
		$msg = 'Action: addCaseContact<br/>\nError: Unable to associate contact with transferred case.<br/>\nResponse: ' . pl_html_escape($response);
		transfer_error($msg,__LINE__,$case_id);
	}	
}

// activities - notes and timekeeping.
$result = $case->getNotes('ASC',10000);
while ($notes = DBResult::fetchRow($result))
{
	$notes['case_id'] = $tx_case_id;
	
	$atty_name = pl_array_lookup($notes['user_id'], $staff_array);
	$notes['notes'] .= "\n\n===\nEntered by {$atty_name}, {$owner_name}";
	$notes['notes'] .= ", {$case_row['number']}";
	unset($notes['user_id']);
	unset($notes['act_id']);

	$data = build_transfer_packet('newActivity',$notes);
	$response = pika_transfer($data,$transfer_option_id);
	if (!is_numeric($response))
	{
		$msg = 'Action: newActivity<br/>\nError: Unable to associate case note with transferred case.<br/>\nResponse: ' . pl_html_escape($response);
		transfer_error($msg,__LINE__,$case_id);
	}	
}

// Set the original case to transferred status.
$case->status = 4;
$case->save();

pl_audit('case.transfer', 'case', $case_id, array(
    'case_number'        => $case->number,
    'transfer_option_id' => $transfer_option_id,
    'remote_case_id'     => $tx_case_id,
));

$number = $case->number;
if(strlen($number) < 1)
{
	$number = 'No Case #';
}
/*	The case number is typed in, and the response line below repeats what
	the receiving installation sent back, so neither goes into the page as
	it stands.
*/
$safe_case_id = rawurlencode((string) $case_id);
$case_url = "<a href=\"{$base_url}/case.php?case_id={$safe_case_id}\">" . pl_clean_html($case->number) . "</a>";

$main_html = array();
$main_html['content'] = "Transfer of case # ".
						$case_url . " ".
						"Complete, transferred case reference number # is '" . pl_html_escape($tx_case_id) . "'.";
$main_html['page_title'] = $page_title = 'Case Transfer';
$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt; {$case_url} &gt; {$page_title}";
$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);
