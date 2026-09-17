<?php 

/*****************************************/
/* Pika CMS (C) 2008 Matthew Friedlander */
/* http://pikasoftware.com               */
/*****************************************/

require_once('pika-danio.php');
pika_init(); 

// This page merges contacts on a GET: the action is dispatched out of the
// query string and the trigger is plain <a href> / method=get markup, so a
// hidden token field is not available as a defence here. On a non-POST
// request pl_csrf_check() falls through to the same-site check, which
// refuses a mutation that a foreign page initiated and needs nothing from
// the markup. See pl_request_cross_site_verdict() in cms/app/lib/pl.php.
pl_csrf_check();
require_once('pikaContact.php');
require_once('plFlexList.php');
require_once('pikaTempLib.php');

$buffer = '';
$a = $main_html = array();

$base_url = pl_settings_get('base_url');

$contact_id = pl_grab_get('contact_id');
$action = pl_grab_get('action');
$offset = pl_grab_get('offset');
$merge_these = pl_grab_get('merge_these');
//$letter = pl_grab_get('letter');

switch ($action) {
	case 'merge':
		/*	A merge folds one contact's records into another and removes the
			one merged away. It ran on nothing but a contact id, so any
			signed-in user could destroy any two contacts in the system by
			typing their ids. Ask permission for both sides: the contact that
			survives, and every contact being folded into it.
			pika_authorize('edit_contact') walks the cases the contact appears
			on and checks edit_case on each.
		*/
		if(is_array($merge_these) && is_numeric($contact_id)
			&& pika_authorize('edit_contact',array('contact_id' => $contact_id))) {
			$contact = new pikaContact($contact_id);
			foreach ($merge_these as $selected_contact_id) {
				// Ensure a number is passed, the record isn't new, and the
				// user may edit the contact being merged away.
				if(is_numeric($selected_contact_id) && !$contact->is_new
					&& pika_authorize('edit_contact',array('contact_id' => $selected_contact_id))) {
					
					if(!$contact->merge($selected_contact_id)) {
						die('An error occured during the merge');
					}
				}
			}
		}
		
		
		
	default:
		$contact = new pikaContact($contact_id);
		$result = $contact->metaphoneContactCheck();
		
		$contact_list = new plFlexList();
		$contact_list->template_file = 'subtemplates/merge_contacts.html';
		
		/*	Every display column on this page goes out through addHtmlRow(),
			which does not escape. That is the documented contract of the
			"html" tier of plFlexList, not an oversight -- the caller owns its
			escaping. This caller was not doing any.
			
			What kept it safe was pl_clean_form_input(), which rewrites < and
			> on every GET and POST value, so a contact typed in through a web
			form cannot carry markup. Nothing else that writes the contacts
			table goes through that filter: the migration and import scripts
			under app/scripts, an admin working directly in the database, and
			any site-local tooling all write the column as given. A contact
			whose address holds `<svg onload=...>` renders as live markup in
			the session of whoever opens the merge-duplicates screen.
			
			The two render blocks below were duplicates, so they collapse into
			one closure. Two details in it are load-bearing:
			
			- text_address in output=html mode interleaves <br/> and &nbsp;
			  with the raw column values, so the finished string CANNOT be
			  escaped -- that would show the line breaks as a literal
			  &lt;br/&gt;. The components are escaped on the way in instead.
			  text_phone emits no markup of its own, so there the finished
			  string is escaped, which reads better.
			- The address components are copied under an isset() guard.
			  text_address treats any truthy value as a line, so handing it a
			  key that was not in the row would print a spurious line.
		*/
		$decorate = function ($row)
		{
			$row['full_phone'] = pl_html_escape(pikaTempLib::plugin('text_phone','phone',$row,null,array('notes')));
			$row['full_alt_phone'] = pl_html_escape(pikaTempLib::plugin('text_phone','alt_phone',$row,null,array('area_code=area_code_alt','phone=phone_alt','notes')));
			
			$addr = array();
			
			foreach (array('org','address','address2','city','state','zip') as $part)
			{
				if (isset($row[$part]))
				{
					$addr[$part] = pl_html_escape($row[$part]);
				}
			}
			
			$row['full_address'] = pikaTempLib::plugin('text_address','full_address',$addr,null,array('output=html'));
			
			if (isset($row['ssn']))
			{
				$row['ssn'] = pl_html_escape($row['ssn']);
			}
			
			$row['full_name'] = pl_html_escape(pikaTempLib::plugin('text_name','contact_name',$row,null,array('order=last')));
			$row['birth_date'] = pl_date_unmogrify($row['birth_date']);
			
			return $row;
		};
		
		if(DBResult::numRows($result) > 0) {
			$i = 2;
			$row = $contact->getValues();
			$row['row_class'] = $i;	
			$row['selected_checkbox'] = '';
			$contact_list->addHtmlRow($decorate($row));
			$i = 1;
			while ($row = DBResult::fetchRow($result)) {
				$row['row_class'] = $i;
				if ($i > 1){$i = 1;}
				else {$i++;}
				$row['selected_checkbox'] = pikaTempLib::plugin('checkbox','merge_these[]',$row['contact_id'],null,array('no_hidden',"default_value={$row['contact_id']}"));
				$contact_list->addHtmlRow($decorate($row));
			}
			
		} 
		$a['contact_list'] = $contact_list->draw();
		
		
		$a['contact_id'] = $contact_id;
		$a['contact_name'] = pikaTempLib::plugin('text_name','contact_name',$contact->getValues());
		$template = new pikaTempLib('subtemplates/merge_contacts.html', $a);
		
		
		$main_html['content'] = $template->draw();
		$main_html['page_title'] = 'Merge Duplicate Contacts';
		$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
					 <a href=\"{$base_url}/contact.php?contact_id={$contact_id}\">
					 {$a['contact_name']}
					 </a> &gt;
					 Merge Duplicate Contacts";
		
}




$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>

