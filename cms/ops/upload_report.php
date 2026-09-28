<?php

chdir('..');
require_once('pika-danio.php');

pika_init();

/*	Every POST to this handler must carry the per-session CSRF token.
	See pl_csrf_check() in cms/app/lib/pl.php for the framework.
	
	js/save_report.js sends the report parameters as an application/json
	request body rather than as a form encoding, so PHP populates no $_POST
	at all and there is no _csrf field for pl_csrf_check() to read. The token
	arrives in an X-CSRF-Token header instead; copy it across before the
	check, which is the same shape the framework expects.
*/
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST')
{
	$csrf_header = isset($_SERVER['HTTP_X_CSRF_TOKEN']) ? (string) $_SERVER['HTTP_X_CSRF_TOKEN'] : '';
	
	if (strlen($csrf_header) > 0 && !isset($_POST['_csrf']))
	{
		$_POST['_csrf'] = $csrf_header;
	}
	
	pl_csrf_check();
}

/*	js/save_report.js used to fire this request and reload the saved-report
	list without ever looking at the answer, so a refusal here was invisible:
	the list came back without the new entry and the person who had just spent
	ten minutes setting up a report was left to work out for themselves that
	nothing had been saved.
	
	The browser now waits for the answer, so this handler has to give one.
	Say OK on the single path that stores a document, and otherwise send a
	status the browser can act on with one line of plain text explaining it.
	The body is text/plain so nothing here can be mistaken for markup, and it
	ends the request the way die() did rather than through pika_exit(), which
	would run the reply through the page template.
*/
function pl_upload_report_reply($status, $message)
{
	if (!headers_sent())
	{
		http_response_code($status);
		header('Content-Type: text/plain; charset=UTF-8');
	}
	
	echo $message;
	exit();
}

/*	This handler stores a report definition, which is a document every
	user of the site then runs. It had no permission check, so any signed-in
	user could install one. Report definitions are administrator material.
*/
if (!pika_authorize('system',array()))
{
	pl_upload_report_reply(403, 'Access denied');
}

require_once('pikaDocument.php');
require_once('pikaMisc.php');

/*	The browser used to send the stored document itself, built by string
	concatenation with no escaping, and this handler parsed it. A setting
	holding < or & broke the save, and the server parsed markup chosen by the
	client. Now the browser sends the form fields as JSON, and the stored
	document is built here with the DOM, so nothing the client sends is ever
	parsed as XML.

	pl_upload_report_fields() returns the decoded fields, or null when the
	body is not exactly the shape js/save_report.js getReportParams() sends.
	Each element type carries exactly the keys that script writes for it, and
	that load_report() reads back.
*/
function pl_upload_report_fields($postText)
{
	$max_elements = 2000;
	$max_options = 2000;
	$max_all_options = 20000;
	$element_keys = array(
		'hidden' => array('name', 'type', 'value'),
		'text' => array('name', 'type', 'value'),
		'textarea' => array('name', 'type', 'value'),
		'checkbox' => array('name', 'type', 'checked'),
		'radio' => array('name', 'type', 'value', 'checked'),
		'select-one' => array('name', 'type', 'options'),
		'select-multiple' => array('name', 'type', 'options'),
	);
	$option_keys = array('selected', 'text', 'value');

	/*	A string the stored document cannot hold: XML 1.0 has no way to
		write most control characters, even as a character reference.
	*/
	$bad_chars = '/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{FFFE}\x{FFFF}]/u';

	if (!is_string($postText) || strlen($postText) < 1)
	{
		return null;
	}

	$data = json_decode($postText, true, 8);

	if (!is_array($data) || count($data) != 2
		|| !array_key_exists('form', $data) || !array_key_exists('elements', $data)
		|| !is_string($data['form']) || preg_match($bad_chars, $data['form'])
		|| !is_array($data['elements'])
		|| $data['elements'] !== array_values($data['elements'])
		|| count($data['elements']) > $max_elements)
	{
		return null;
	}

	$all_options = 0;

	foreach ($data['elements'] as $element)
	{
		if (!is_array($element) || !isset($element['type']) || !is_string($element['type'])
			|| !isset($element_keys[$element['type']]))
		{
			return null;
		}

		$keys = array_keys($element);
		$want = $element_keys[$element['type']];
		sort($keys);
		sort($want);

		if ($keys !== $want || !is_string($element['name'])
			|| preg_match($bad_chars, $element['name']))
		{
			return null;
		}

		if (array_key_exists('value', $element)
			&& (!is_string($element['value']) || preg_match($bad_chars, $element['value'])))
		{
			return null;
		}

		if (array_key_exists('checked', $element) && !is_bool($element['checked']))
		{
			return null;
		}

		if (!array_key_exists('options', $element))
		{
			continue;
		}

		$options = $element['options'];

		if (!is_array($options) || $options !== array_values($options)
			|| count($options) > $max_options)
		{
			return null;
		}

		$all_options += count($options);

		if ($all_options > $max_all_options)
		{
			return null;
		}

		foreach ($options as $option)
		{
			if (!is_array($option))
			{
				return null;
			}

			$keys = array_keys($option);
			sort($keys);

			if ($keys !== $option_keys
				|| !is_string($option['value']) || preg_match($bad_chars, $option['value'])
				|| !is_string($option['text']) || preg_match($bad_chars, $option['text'])
				|| !is_bool($option['selected']))
			{
				return null;
			}
		}
	}

	return $data;
}

/*	Build the document the browser used to send, element for element:

	<form name="..."><element><name/><type/><value/><checked/><options>
	<option><value/><text/><selected/></option></options></element></form>

	Each element holds only the children its type carries. Booleans are the
	strings true and false, as JavaScript wrote them. An empty string gets no
	text node, so it is stored as an empty element, the same as before;
	load_report() checks hasChildNodes() for that case.
*/
function pl_upload_report_xml($fields)
{
	$xml_doc = new DOMDocument('1.0', 'UTF-8');
	$form = $xml_doc->createElement('form');
	$form->setAttribute('name', $fields['form']);
	$xml_doc->appendChild($form);

	$add = function ($parent, $tag, $text) use ($xml_doc)
	{
		$node = $xml_doc->createElement($tag);

		if (is_bool($text))
		{
			$text = $text ? 'true' : 'false';
		}

		if (strlen($text) > 0)
		{
			$node->appendChild($xml_doc->createTextNode($text));
		}

		$parent->appendChild($node);
		return $node;
	};

	foreach ($fields['elements'] as $element)
	{
		$node = $xml_doc->createElement('element');
		$form->appendChild($node);
		$add($node, 'name', $element['name']);
		$add($node, 'type', $element['type']);

		if (array_key_exists('value', $element))
		{
			$add($node, 'value', $element['value']);
		}

		if (array_key_exists('checked', $element))
		{
			$add($node, 'checked', $element['checked']);
		}

		if (array_key_exists('options', $element))
		{
			$options = $add($node, 'options', '');

			foreach ($element['options'] as $option)
			{
				$option_node = $add($options, 'option', '');
				$add($option_node, 'value', $option['value']);
				$add($option_node, 'text', $option['text']);
				$add($option_node, 'selected', $option['selected']);
			}
		}
	}

	return $xml_doc;
}

/*	Initialised before the branch, so a non-POST request reads an empty body
	rather than an undefined variable.
*/
$postText = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST')
{
	$postText = file_get_contents('php://input');
}

$report_name = pl_grab_get('report_name');
$doc_name = pl_grab_get('doc_name');
$report_list = pikaMisc::reportList();

if (!$report_name)
{
	pl_upload_report_reply(400, 'The report was not saved: the request did not say which report it belongs to.');
}

$fields = pl_upload_report_fields($postText);

if (null === $fields)
{
	pl_upload_report_reply(400, 'The report was not saved: the settings did not arrive in a readable form.');
}

$xml_doc = pl_upload_report_xml($fields);

//print_r($report_list);
$contents = $xml_doc->saveXML();
if(function_exists('mb_strlen')) {
	$doc_size = mb_strlen($contents);	
} else {
	$doc_size = strlen($contents);
}
$doc = new pikaDocument();
$doc->doc_data = addslashes(gzcompress($contents,9));
$report_file_name = $report_name . ' Saved ' . date('m/d/Y');
if($doc_name && strlen($doc_name))	{
	$report_file_name = $doc_name;
}


/*	A foreach over $result stood here. Nothing in this file ever
	assigned $result, so on PHP 8 it was a warning on every save and
	nothing else: the loop body could not run. Removed rather than
	guarded, because there is no value to guard.
*/
$doc->doc_name = $report_file_name;
$doc->report_name = $report_name;
$doc->description = $report_name . " saved " . date('m/d/Y');
$doc->mime_type = 'text/xml';
$doc->doc_type = 'R';
$doc->doc_size = $doc_size;
$doc->user_id = $auth_row['user_id'];
$doc->created = date('Y-m-d');
$doc->save();

pl_upload_report_reply(200, 'OK');
