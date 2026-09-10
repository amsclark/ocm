<?php
define('PL_DISABLE_SECURITY', true);

chdir('../');
require_once('pika-danio.php');
pika_init();

require_once('pikaActivity.php');
require_once('pikaCase.php');

/*	Verify Twilio's request signature before doing anything else.

	This endpoint runs with PL_DISABLE_SECURITY, so there is no session and
	no authorization gate: it accepted whatever anyone posted to it. That
	was enough to write an activity record, with attacker-chosen notes, onto
	any open case whose client phone number the caller could guess, and to
	send the case handlers an email about it. The reply is also an oracle:
	the wording differs depending on whether the number matched an open
	case, so the endpoint answered "is this person a client of yours" to
	anyone who asked. For a domestic violence caseload that answer is the
	thing most worth protecting.

	Twilio signs every webhook with the account auth token. The signature is
	the base64 HMAC-SHA1 of the full request URL followed by each POST
	parameter name and value in name order. Recomputing it here needs no
	library.

	The only legitimate caller is Twilio's inbound webhook, which is a POST,
	so anything else is refused before the signature is even considered.
*/
if (!isset($_SERVER['REQUEST_METHOD']) || 'POST' !== $_SERVER['REQUEST_METHOD'])
{
	header('HTTP/1.1 405 Method Not Allowed');
	header('Allow: POST');
	header('Content-Type: text/plain; charset=utf-8');
	exit("POST only.\n");
}

$twilio_auth_token = pl_settings_get('twilio_auth_token');

if (!is_string($twilio_auth_token) || strlen($twilio_auth_token) < 1)
{
	/*	Refuse rather than fall back to accepting unsigned requests. An
		installation that has not configured SMS has nothing to lose by this
		endpoint being closed; one that has, cannot afford it being open.
	*/
	pl_audit('twilio.webhook.rejected', 'twilio', null, array(
		'reason' => 'auth_token_not_configured',
		'remote_ip' => isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : null
	));
	header('HTTP/1.1 403 Forbidden');
	header('Content-Type: text/plain; charset=utf-8');
	exit("Twilio webhook rejected: signature verification not configured.\n");
}

/*	Rebuild the URL Twilio signed. Twilio hashes the absolute URL it was
	configured with, including the query string, so a deployment behind a
	TLS-terminating proxy has to sign with the public-facing URL and not the
	internal one. The forwarded headers are consulted for that reason; they
	are client-supplied, but they cannot be used to forge a signature -- a
	caller who alters them only changes the string being hashed, and the
	HMAC then fails to match.
*/
$twilio_scheme = 'http';

if (!empty($_SERVER['HTTPS']) && 'off' !== $_SERVER['HTTPS'])
{
	$twilio_scheme = 'https';
}

else if (isset($_SERVER['HTTP_X_FORWARDED_PROTO'])
	&& 'https' === strtolower((string) $_SERVER['HTTP_X_FORWARDED_PROTO']))
{
	$twilio_scheme = 'https';
}

$twilio_host = '';

if (isset($_SERVER['HTTP_X_FORWARDED_HOST']) && strlen((string) $_SERVER['HTTP_X_FORWARDED_HOST']) > 0)
{
	$twilio_host = (string) $_SERVER['HTTP_X_FORWARDED_HOST'];
}

else if (isset($_SERVER['HTTP_HOST']) && strlen((string) $_SERVER['HTTP_HOST']) > 0)
{
	$twilio_host = (string) $_SERVER['HTTP_HOST'];
}

else if (isset($_SERVER['SERVER_NAME']))
{
	$twilio_host = (string) $_SERVER['SERVER_NAME'];
}

$twilio_url = $twilio_scheme . '://' . $twilio_host
	. (isset($_SERVER['REQUEST_URI']) ? (string) $_SERVER['REQUEST_URI'] : '');

$twilio_signed = $twilio_url;
$twilio_params = $_POST;
ksort($twilio_params);

foreach ($twilio_params as $twilio_key => $twilio_value)
{
	// Twilio sends flat parameters. An array here is not something Twilio
	// produced, so it cannot be part of a valid signature.
	if (is_array($twilio_value))
	{
		$twilio_signed = null;
		break;
	}
	
	$twilio_signed .= $twilio_key . $twilio_value;
}

$twilio_signature = isset($_SERVER['HTTP_X_TWILIO_SIGNATURE'])
	? (string) $_SERVER['HTTP_X_TWILIO_SIGNATURE']
	: '';

$twilio_expected = is_null($twilio_signed)
	? ''
	: base64_encode(hash_hmac('sha1', $twilio_signed, $twilio_auth_token, true));

// hash_equals, not ==, so the comparison does not leak the correct
// signature one byte at a time.
if ('' === $twilio_signature
	|| '' === $twilio_expected
	|| !hash_equals($twilio_expected, $twilio_signature))
{
	pl_audit('twilio.webhook.rejected', 'twilio', null, array(
		'reason' => ('' === $twilio_signature) ? 'missing_signature' : 'bad_signature',
		'remote_ip' => isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : null,
		'webhook_url' => $twilio_url
	));
	header('HTTP/1.1 403 Forbidden');
	header('Content-Type: text/plain; charset=utf-8');
	exit("Twilio webhook rejected: signature verification failed.\n");
}


function send_mail_notification($user_id, $case_id, $case_number, $sender_name)
{
	$safe_user_id = DB::escapeString($user_id);
	
	if (is_numeric($safe_user_id) 
			&& strlen(pl_settings_get('sparkpost_from_address')) > 0 
			&& strlen(pl_settings_get('sparkpost_api_key')) > 0)
	{
		$result = DB::query("SELECT email FROM users WHERE user_id = {$safe_user_id}");
		$row = DBResult::fetchRow($result);
		
		// Send email via SparkPost.
		$to = $row['email'];
		
		if (strlen($to) < 6)
		{
			return false;
		}
		
		if (strlen($case_number) < 1)
		{
			$case_number = "case record {$case_id}";
		}
		
		$base_url = pl_settings_get('base_url');
		$subject = "New SMS for {$case_number}";
		// The link was built from $_SERVER['SERVER_NAME'], which Apache
		// fills from the request's Host header by default. See
		// pl_canonical_origin().
		$message = "{$sender_name} has sent a new SMS message, you can view it at:  "
			. pl_canonical_origin() . "{$base_url}/case.php?case_id={$case_id}&screen=sms";
		
		$data_string = '{"options": {"sandbox": false, "open_tracking": false, "click_tracking": false}, "content": {"from": "' 
			. pl_settings_get('sparkpost_from_address') 
			. '", "subject": "' . $subject . '", "text":"' . $message 
			. '"}, "recipients": [{"address": "' . $to . '"}]}';
		
		$c = curl_init();
		curl_setopt($c, CURLOPT_URL, 'https://api.sparkpost.com/api/v1/transmissions');
		curl_setopt($c, CURLOPT_CUSTOMREQUEST, 'POST');
		curl_setopt($c, CURLOPT_TIMEOUT, 30);
		curl_setopt($c, CURLOPT_RETURNTRANSFER, 1);
		curl_setopt($c, CURLOPT_SSLVERSION, 6);
		curl_setopt($c, CURLOPT_POSTFIELDS, $data_string);
		curl_setopt($c, CURLOPT_HTTPHEADER, array(
                                            'Content-Type: application/json',
                                            'Authorization: ' . pl_settings_get('sparkpost_api_key')
                                            ));
		//$status_code = curl_getinfo($c, CURLINFO_HTTP_CODE);
		$exit_code = curl_exec($c);
		curl_close ($c);
		$exit_array = json_decode($exit_code);
		
		return $exit_array->total_accepted_recipients;
	}
	
	return false;
}


// Main code
$number = isset($_POST['From']) ? (string) $_POST['From'] : '';
$body = isset($_POST['Body']) ? (string) $_POST['Body'] : '';

$case_id = '';

$clean_number = DB::escapeString($number);
$phone = substr($clean_number, 5, 3) . '-' . substr($clean_number, 8);
$area_code = substr($clean_number, 2, 3);

$response_message = "If you are getting this message, an error has occurred.";

$result = DB::query("SELECT conflict.case_id, first_name, middle_name, last_name, extra_name 
	FROM contacts 
	LEFT JOIN conflict ON contacts.contact_id = conflict.contact_id
	LEFT JOIN cases ON conflict.case_id = cases.case_id
	WHERE conflict.relation_code = 1
	AND cases.close_date IS NULL 
	AND cases.case_id IS NOT NULL 
	AND ((area_code = '{$area_code}' AND phone = '{$phone}') 
	OR (area_code_alt = '{$area_code}' AND phone_alt = '{$phone}'))");
	
$i = DBResult::numRows($result);
$j = 0;  // Use this to keep track of whether this is the first row processed.

while ($row = DBResult::fetchRow($result))
{
	$case_id = $row['case_id'];
	$sender_name = pl_text_name($row);
	$a = new pikaActivity();
	$a->act_type = 'S';
	$a->act_date = date('Y-m-d');
	$a->act_time = date('H:i:s');
	$a->notes = $body;
	$a->summary = "[SMS message from {$sender_name} at ({$area_code}) {$phone}]";
	$a->case_id = $case_id;
	
	if ($j == 0)
	{
		$a->sms_count = 2;
	}
	
	$a->save();

	if ($case_id != '')
	{
		// Send mail notification to the case handlers.
		$c = new pikaCase($case_id);
		send_mail_notification($c->user_id, $c->case_id, $c->number, $sender_name);
		send_mail_notification($c->cocounsel1, $c->case_id, $c->number, $sender_name);
		send_mail_notification($c->cocounsel2, $c->case_id, $c->number, $sender_name);
		
		// Then increment the unread_sms counter for this case.
		$c->unread_sms++;
		$c->save();
	}
	
	$j++;
}

if ($i > 0)
{
	// Use the act ID from the last activity record created.
	$response_message = "Thanks!  Your message has been sent to your case handlers. The confirmation ID for your message is {$a->act_id}.";
}

else
{
	$response_message = "Thank you for texting us! We couldn't find your phone"
		. " number in any of our open cases. Please call our office";
	$office_phone = pl_settings_get('office_phone');
	
	if (strlen($office_phone) > 6)
	{
		$response_message .= " at {$office_phone}.";
	}
	
	else 
	{
		$response_message .= ".";
	}
}

$response_message = htmlspecialchars($response_message);

header('Content-Type: text/xml');
?>
 
<Response>
    <Message>
        <?php echo $response_message ?>
    </Message>
</Response>
