<?php

/***************************/
/* Pika CMS (C) 2011       */
/* Pika Software, LLC.     */
/* http://pikasoftware.com */
/***************************/

chdir('../');

define('PL_HTTP_SECURITY',true);

require_once ('pika-danio.php');
pika_init();
require_once('pikaCase.php');
require_once('pikaContact.php');
require_once('pikaActivity.php');

$auth_row = pikaAuthHttp::getInstance()->getAuthRow();

$user_id = $auth_row['user_id'];

$action = pl_grab_post('action');
$format = pl_grab_post('format');

/*	The signature covers the bytes the peer sent, so the body is read here
	without going through pl_grab_post().
	
	pl_grab_post() runs pl_clean_form_input(), which trims the ends and
	rewrites < and > as &lt; and &gt;. The HMAC used to be checked against
	that rewritten copy, so a peer that signed what it actually sent was
	refused with bad_signature as soon as any case field held a < or a > -
	"rent < $500" in a note was enough - and the only body that got through
	was one signed over the escaped form. The same rewrite changed the byte
	lengths inside a serialize() body, so the legacy format could not carry
	those characters at all.
	
	Nothing reads this string except the signature comparison and the
	decoder below. The decoded array is escaped before any handler sees it.
*/
$raw = (isset($_POST['payload']) && is_string($_POST['payload'])) ? $_POST['payload'] : null;
$raw_action = (isset($_POST['action']) && is_string($_POST['action'])) ? $_POST['action'] : '';

/*	How the body is read.
	
	This endpoint accepts a case, a contact or an activity pushed in by
	another OCM installation. HTTP Basic, checked above, proves which peer
	account sent the request. It does not prove that the body is safe to
	deserialize, and the body used to be read with unserialize(): a
	serialized string names the classes to build, and building them runs
	whatever their constructors and destructors do. That is object
	injection (CWE-502), and an account with peer-transfer rights is not
	the same thing as permission to run code.
	
	So there are two formats:
	
	  format=json  A JSON body with an HMAC-SHA256 signature over
	               action + "\n" + payload + "\n" + ts, keyed on the
	               peer_transfer_shared_secret setting. ts must be within
	               300 seconds of this server's clock, which bounds how
	               long a captured request stays replayable. Use this.
	
	  anything     The historical serialize() body. Refused unless an
	  else         operator sets
	               peer_transfer_allow_legacy_unserialize, and even then
	               decoded with allowed_classes => false, so that no
	               object of any class can come out of it. It exists only
	               to drain pushes queued by a peer that has not upgraded.
	
	Both settings ship blank/0, so a deployment that has not configured
	peer transfer accepts nothing here.
	
	Every request is audited, accepted or rejected, with a reason.
*/
$peer_user = isset($auth_row['username']) ? (string) $auth_row['username'] : null;

$payload = null;
if ('json' === $format)
{
	$secret = pl_settings_get('peer_transfer_shared_secret');
	if (!is_string($secret) || 0 === strlen($secret))
	{
		peer_transfer_reject('shared_secret_not_configured',$action,$peer_user);
	}
	
	$ts = pl_grab_post('ts');
	$signature = pl_grab_post('signature');
	if (!is_string($raw) || !is_string($ts) || !is_string($signature))
	{
		peer_transfer_reject('missing_signature_or_ts',$action,$peer_user);
	}
	if (!ctype_digit($ts))
	{
		peer_transfer_reject('invalid_ts',$action,$peer_user);
	}
	if (abs(time() - (int) $ts) > 300)
	{
		peer_transfer_reject('ts_out_of_window',$action,$peer_user);
	}
	
	/*	hash_equals, not ==, so that a wrong signature always costs the
		same time to reject and cannot be guessed one byte at a time.
	*/
	$expected = hash_hmac('sha256',$raw_action . "\n" . $raw . "\n" . $ts,$secret);
	if (!hash_equals($expected,$signature))
	{
		peer_transfer_reject('bad_signature',$action,$peer_user);
	}
	
	$decoded = json_decode($raw,true);
	if (!is_array($decoded))
	{
		peer_transfer_reject('bad_json_payload',$action,$peer_user);
	}
	$payload = $decoded;
}
else
{
	if ('1' !== (string) pl_settings_get('peer_transfer_allow_legacy_unserialize'))
	{
		peer_transfer_reject('legacy_unserialize_disabled',$action,$peer_user);
	}
	
	/*	allowed_classes => false turns every serialized object into an
		__PHP_Incomplete_Class, so no constructor or destructor from this
		string runs. The handlers below want an array anyway.
	*/
	$payload = @unserialize((string) $raw,array('allowed_classes' => false));
	if (!is_array($payload))
	{
		peer_transfer_reject('bad_serialized_payload',$action,$peer_user);
	}
}

/*	Escape the payload the way a browser submission is escaped.
	
	Everything a user types reaches a column through pl_grab_var(), which runs
	pl_clean_form_input() and rewrites < and > as &lt; and &gt;. This endpoint
	went from json_decode() straight to setValues(), so nothing in it asked for
	that escaping. Until the signature fix below it got it by accident: the body
	was read through pl_grab_post(), which had already cleaned it - which is
	also why an honestly signed body was refused. Now that the raw bytes are
	read for the signature, the escaping has to be asked for here, or a peer
	installation becomes the one writer on the box that can put a raw < into a
	contact name, a case field or an activity summary. The list pages draw cell
	values as they come out of the row, so that text would run as script on the
	screen of whoever searched for the record.
	
	cms/services/transfer_case_v2.php and transfer_case_lsxml.php already clean
	their bodies this way. pl_clean_form_input() walks an array and keeps its
	keys, so the addCaseContact handler still reads $payload[0..2] and the
	numeric tests below still work.
*/
$payload = pl_clean_form_input($payload);

pl_audit('peer_transfer.accepted','peer_transfer',null,array(
	'action' => (string) $action,
	'format' => ('json' === $format) ? 'json' : 'legacy',
	'peer_user' => $peer_user
	));

$buffer = '';
switch ($action)
{
	case 'newCase':
		$case = new pikaCase();
		$unset_fields = array(	'case_id','number','office',
								'user_id','cocounsel','cocounsel2','intake_user_id',
								'pba_id1','pba_id2','pba_id3',
								'created','close_date','close_code','outcome','reject_code',
								'poten_conflicts','status'
								);
		foreach ($unset_fields as $key)
		{
			if_unset($payload,$key);
		}
		$case->setValues($payload);
		$case->status = 1;
		$case->save();
		$buffer = $case->case_id;
		break;
	case 'newContact':
		$contact = new pikaContact();
		if_unset($payload,'contact_id');
		$contact->setValues($payload);
		$contact->save();
		
		$buffer = $contact->contact_id;
		break;
	case 'addCaseContact':
		if(isset($payload[0]) && is_numeric($payload[0]))
		{
			$case = new pikaCase($payload[0]);
			if(isset($payload[1]) && is_numeric($payload[1]) && $payload[2] && is_numeric($payload[2]))
			{			
				$case->addContact($payload[1],$payload[2]);
				$buffer = $payload[1];
			}
		}
		break;
	case 'newActivity':
		$activity = new pikaActivity();
		if(isset($payload['act_id']))
		{
			unset($payload['act_id']);
		}
		$activity->setValues($payload);
		$activity->user_id = $user_id;
		$activity->hours = null;  // AMW 2013-04-08 - based on feedback from LSNM.
		$activity->save();
		$buffer = $activity->act_id;
		break;
	
	default:
		$buffer = 'Error: Unrecognized Action';
		break;
}

echo $buffer;
exit();


function if_unset(&$data,$key)
{
	if(isset($data[$key]))
	{
		unset($data[$key]);
	}
}

/*	Refuse the request, and leave a record of why. Called before anything
	has been written, so there is nothing to roll back.
*/
function peer_transfer_reject($reason,$action,$peer_user)
{
	pl_audit('peer_transfer.rejected','peer_transfer',null,array(
		'reason' => $reason,
		'action' => (string) $action,
		'peer_user' => $peer_user,
		'remote_ip' => isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : null
		));
	header('HTTP/1.1 403 Forbidden');
	header('Content-Type: text/plain; charset=utf-8');
	echo "Peer transfer rejected: {$reason}\n";
	exit();
}

