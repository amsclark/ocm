function reload (name) {
	fileList(name,0,'edit_select','R','parent_folder','form_id','','%%[report_name]%%'); 
}

// Per-session CSRF token for the save_report POST. The request body is raw
// XML, not a form encoding, so ops/upload_report.php cannot find a _csrf field
// in $_POST; it reads this header instead. The token comes from the hidden
// input the docgen form on the report page carries -- see the %%[csrf_field]%%
// tag in reports/*/form.html -- with a fall back to any other _csrf input on
// the page.
function srCsrfToken() {
	var any = document.querySelector('input[name="_csrf"]');
	return any ? any.value : '';
}

/*	The save fired and the list was reloaded on the next line, without ever
	looking at the answer. Nothing waited for the request, so every refusal
	-- an expired session, a CSRF token that no longer matched, an account
	without the rights to install a report definition -- looked exactly like
	a successful save: the list came back, the new entry was simply not in
	it, and the settings the person had just spent their time on were gone.
	
	So wait for the answer. Reload the list only when the handler says the
	document was stored, and say so plainly when it was not.
	
	The request object is local. The one this function used to take was the
	page-wide xmlHttp that load_report() also reads from in its own callback,
	so a save started while a load was still in flight replaced the object
	that callback was about to read.
*/
function save_report(form_container,save_as) {
	
	var xhr = GetXmlHttpObject();
	if (xhr==null) {
  		alert ("Your browser does not support AJAX!");
  		return;
	}
	
	var report_name = '%%[report_name]%%';
	var doc_name = '';
	if(document.getElementById(save_as).value != null) {
		doc_name = escape(document.getElementById(save_as).value);
	}
	
	var url="%%[base_url]%%/ops/upload_report.php?report_name=%%[report_name]%%&doc_name=" + doc_name;
	var xml=getReportParams(form_container,report_name,save_as);
	
	xhr.onreadystatechange=function() {
		if (xhr.readyState!=4 && xhr.readyState!="complete") { return; }
		
		var body = xhr.responseText ? xhr.responseText.replace(/^\s+|\s+$/g,'') : '';
		
		if (xhr.status==200 && body=='OK') {
			reload('saved_reports');
			return;
		}
		
		// Only the handler's own one-line replies are shown to the person.
		// pl_csrf_check() answers with a whole HTML page, which would be
		// read out as markup in an alert box.
		var reason = '';
		if (body.length && body.length < 200 && body.indexOf('<') < 0) {
			reason = ' ' + body;
		}
		
		if (xhr.status==0) {
			alert('This report was not saved: the server could not be reached. Your settings are still on this page.');
			return;
		}
		
		if (xhr.status==403) {
			alert('This report was not saved: the site refused the request.' + reason
				+ ' If you have been signed in for a while, open the report page again and retry.');
			return;
		}
		
		alert('This report was not saved.' + reason + ' Your settings are still on this page.');
	}
	
	xhr.open("POST", url, true)
	xhr.setRequestHeader("Content-type", "text/xml")
	xhr.setRequestHeader("X-CSRF-Token", srCsrfToken());
	xhr.send(xml);
}

function load_report(form_container,doc_id) {
	
	if (doc_id.length < 1) { return; }
	
	xmlHttp=GetXmlHttpObject();
	if (xmlHttp==null) {
  		alert ("Your browser does not support AJAX!");
  		return;
	}
	
	xmlHttp.onreadystatechange=function() { 
        if (xmlHttp.readyState==4 || xmlHttp.readyState=="complete") {
            if (xmlHttp.status==200) {
            	if(xmlHttp.responseText != null) {
            		//alert(xmlHttp.responseText);
            		loadReportParams(form_container);	
            	} else {
            		return false;
            	}
            	
            }
        }
	}
	
	var url="%%[base_url]%%/documents.php?action=download";
	url=url+"&doc_id="+doc_id;
	//alert(url);
	xmlHttp.open("GET",url,true);
	xmlHttp.send(null);
}


function getReportParams(form_container) {
	
	var elem = document.getElementById(form_container).elements;
	
	
	//alert(report_name);
	var str = '<' + '?xml' + ' version="1.0"' +  ' encoding="UTF-8"?>';
	
	
	str += '<form name="' + form_container + '">';
	//str += '<form name="' + form_container + '" report_name="' + report_name + '" report_file_name="' + report_file_name + '">';
	//alert(str);
	for(var i = 0;i<elem.length;i++) {
		if((elem[i].type == 'hidden' && elem[i].value != 0) || elem[i].type == 'text' || elem[i].type == 'textarea') {
			str += '<element>';
			str += '<name>' + elem[i].name + '</name>';
			str += '<type>' + elem[i].type + '</type>';
			str += '<value>' + elem[i].value + '</value>';
			str += '</element>';
		}
		if(elem[i].type == 'checkbox' && elem[i].checked) {
			str += '<element>';
			str += '<name>' + elem[i].name + '</name>';
			str += '<type>' + elem[i].type + '</type>';
			str += '<checked>' + elem[i].checked + '</checked>';
			str += '</element>';
		}
		if(elem[i].type == 'radio') {
			str += '<element>';
			str += '<name>' + elem[i].name + '</name>';
			str += '<type>' + elem[i].type + '</type>';
			str += '<value>' + elem[i].value + '</value>';
			str += '<checked>' + elem[i].checked + '</checked>';
			str += '</element>';
		}
		if(elem[i].type == 'select-one' || elem[i].type == 'select-multiple') {
			str += '<element>';
			str += '<name>' + elem[i].name + '</name>';
			str += '<type>' + elem[i].type + '</type>';
			str += '<options>';
			for(var j = 0;j<elem[i].options.length;j++) {
				str += '<option>';
				var value = elem[i].options[j].value;
				if(value == '<') {value = '&lt;';}
				if(value == '>') {value = '&gt;';}
				var text = elem[i].options[j].text;
				if(text == '<') {text = '&lt;';}
				if(text == '>') {text = '&gt;';}
				str += '<value>' + value + '</value>';
				str += '<text>' + text + '</text>';
				str += '<selected>' + elem[i].options[j].selected + '</selected>';
				str += '</option>';
			}
			str += '</options>';
			str += '</element>';
		}
		
	}
	str += '</form>';
	//output_container = document.getElementById('test');
	//output_container.value = str;
	//alert(str);
	return str; 
}

function loadReportParams(form_container) {
	
	xmlDoc=xmlHttp.responseXML;
  	var elem = document.getElementById(form_container).elements;
  	var form_xml = xmlDoc.getElementsByTagName("element");
  	// Walk through each item on form
  	for(var i = 0;i<elem.length;i++) {
  		var name = elem[i].name;
  		var type = elem[i].type;
  		
  		// Walk through each item in XML looking for match
  		for(var iNode = 0;iNode<form_xml.length;iNode++) {
  			var elem_name = form_xml[iNode].getElementsByTagName('name')[0].firstChild.nodeValue;
  			var elem_type = form_xml[iNode].getElementsByTagName('type')[0].firstChild.nodeValue;
  			if(name == elem_name  && type == elem_type) {
  				// Text types - simplest - only need to replace value
  				if(elem_type == 'hidden' || elem_type == 'text' || elem_type == 'textarea') {
  					var value = '';
  					if(form_xml[iNode].getElementsByTagName('value')[0].hasChildNodes()) {
  						value = form_xml[iNode].getElementsByTagName('value')[0].firstChild.nodeValue;
  					}
  					elem[i].value = value;
  					//alert(elem_name + ": " + value);
  				}
  				// Checkboxes - only need to determine checked
  				if(elem_type == 'checkbox') {
  					if(form_xml[iNode].getElementsByTagName('checked')[0].firstChild.nodeValue == 'true') {
  						elem[i].checked = true;
  						//alert(elem_name);
  					} else {
  						elem[i].checked = false;
  					}
  				}
  				// Radio - need to check value and set checked
  				if(elem_type == 'radio') {
  					var value = '';
  					if(form_xml[iNode].getElementsByTagName('value')[0].hasChildNodes()) {
  						value = form_xml[iNode].getElementsByTagName('value')[0].firstChild.nodeValue;
  					}
  					if(form_xml[iNode].getElementsByTagName('checked')[0].firstChild.nodeValue == 'true' && elem[i].value == value) {
  						elem[i].checked = true;
  					} 
  				}
  				// Dropdowns - Replace all options and mark selected
  				if(elem_type == 'select-one' || elem_type == 'select-multiple') {
  					var xml_options = form_xml[iNode].getElementsByTagName('option');
  					elem[i].length = 0;
  					for(var opt_list = 0;opt_list<xml_options.length;opt_list++) {
  						var opt_label = '';
  						if(xml_options[opt_list].getElementsByTagName('text')[0].firstChild.nodeValue != null) {
  							opt_label = xml_options[opt_list].getElementsByTagName('text')[0].firstChild.nodeValue;
  						}
  						var opt_value = '';
  						if(xml_options[opt_list].getElementsByTagName('value')[0].hasChildNodes()) {
  							opt_value = xml_options[opt_list].getElementsByTagName('value')[0].firstChild.nodeValue;
  						}
  						elem[i].options[opt_list] = new Option(opt_label,opt_value);
  						if(xml_options[opt_list].getElementsByTagName('selected')[0].firstChild.nodeValue) {
  							if(xml_options[opt_list].getElementsByTagName('selected')[0].firstChild.nodeValue == 'true') {
  								elem[i].options[opt_list].selected = true;
  							} else {
  								elem[i].options[opt_list].selected = false;
  							}
  						}
  					}
  				}
  			}
		}
  	}
	
	
	
}