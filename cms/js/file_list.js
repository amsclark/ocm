function fileList(container,folder_ptr,mode,doc_type,folder_field,doc_field,case_id,report_name) {
	xmlHttp=GetXmlHttpObject();
	if (xmlHttp==null) {
  		alert ("Your browser does not support AJAX!");
  		return;
	}
	
	xmlHttp.onreadystatechange=function() { 
        if (xmlHttp.readyState==4 || xmlHttp.readyState=="complete") {
            if (xmlHttp.status==200) {
            	if(xmlHttp.responseText) {
            		updateCurrentFolder(folder_field,folder_ptr);
            		updateCurrentDoc(doc_field,null);
            		draw(container);
            	} else {
            		document.location.reload(true);
            		return false;
            	}
            	
            }
        }
	}
	var url="%%[base_url]%%/documents.php";
	url=url+"?folder_ptr="+folder_ptr; // Folder PTR
	url=url+"&mode="+mode; // Mode (ex edit/select)
	url=url+"&doc_type="+doc_type; // Mode (ex edit/select)
	url=url+"&container="+container;
	url=url+"&folder_field="+folder_field; // id of current folder pointer
	url=url+"&doc_field="+doc_field; // id of current doc pointer
	url=url+"&case_id="+case_id; 
	url=url+"&report_name="+report_name;
	//alert(url);
	//alert(container+','+folder_ptr+','+mode+','+doc_type+','+folder_field+','+case_id+','+report_name);
	xmlHttp.open("GET",url,true);
	xmlHttp.send(null);
}



function editFile(container,doc_id,mode,doc_type,folder_field,doc_field) {
	xmlHttp=GetXmlHttpObject();
	if (xmlHttp==null) {
  		alert ("Your browser does not support AJAX!");
  		return;
	}
	
	xmlHttp.onreadystatechange=function() { 
        if (xmlHttp.readyState==4 || xmlHttp.readyState=="complete") {
            if (xmlHttp.status==200) {
            	if(xmlHttp.responseText) {
            		draw(container);
            	} else {
            		document.location.reload(true);
            		return false;
            	}
            	
            }
        }
	}
	var url="%%[base_url]%%/documents.php";
	url=url+"?action=edit"; // Folder PTR
	url=url+"&mode="+mode; // Mode (ex edit/select)
	url=url+"&doc_type="+doc_type; // Doc Type (ex C/R/F)
	url=url+"&container="+container; // div id
	url=url+"&folder_field="+folder_field; // id of current folder pointer
	url=url+"&doc_field="+doc_field; // id of current doc pointer
	url=url+"&doc_id="+doc_id; // doc_id
	//alert(url);
	xmlHttp.open("GET",url,true);
	xmlHttp.send(null);
}

function confirmDeleteFile(container,folder_ptr,mode,doc_type,folder_field,doc_field,case_id,report_name,doc_id) {
	xmlHttp=GetXmlHttpObject();
	if (xmlHttp==null) {
  		alert ("Your browser does not support AJAX!");
  		return;
	}
	
	xmlHttp.onreadystatechange=function() { 
        if (xmlHttp.readyState==4 || xmlHttp.readyState=="complete") {
            if (xmlHttp.status==200) {
            	if(xmlHttp.responseText != null) {
            		draw(container);
            	} else {
            		document.location.reload(true);
            		return false;
            	}
            	
            }
        }
	}
	var url="%%[base_url]%%/documents.php";
	url=url+"?action=confirm_delete"; // Folder PTR
	url=url+"&mode="+mode; // Mode (ex edit/select/edit_select)
	url=url+"&doc_type="+doc_type; // Doc Type (ex C/R/F)
	url=url+"&container="+container; // div id
	url=url+"&folder_field="+folder_field; // id of current folder pointer
	url=url+"&doc_field="+doc_field; // id of current doc pointer	
	url=url+"&doc_id="+doc_id; // doc_id
	//alert(url);
	xmlHttp.open("GET",url,true);
	xmlHttp.send(null);
}

function updateFile(container,folder_ptr,mode,doc_type,folder_field,doc_field,case_id,report_name,form_name) {
	xmlHttp=GetXmlHttpObject();
	if (xmlHttp==null) {
  		alert ("Your browser does not support AJAX!");
  		return;
	}
	
	xmlHttp.onreadystatechange=function() { 
        if (xmlHttp.readyState==4 || xmlHttp.readyState=="complete") 
        {
            if (xmlHttp.status==200 && xmlHttp.responseText == '1') 
            {
            		fileList(container,folder_ptr,mode,doc_type,folder_field,doc_field,case_id,report_name);	
            }
            	
        }
        
	}
	var url="%%[base_url]%%/documents.php";
	url=url+"?action=update"; // Folder PTR
	var all_elem = document.getElementsByTagName('*');
	//alert(all_elem.length);
	//var str = '';
	//for(var i = 0;i<all_elem.length;i++) {
	//  	str += all_elem[i].name + ':' + all_elem[i].type + "\n";
	//}
	//alert(str);
	var elem = document.getElementById(form_name).elements;
	
	for(var i = 0;i<elem.length;i++) {
		if((elem[i].type == 'hidden' && elem[i].value != 0) || elem[i].type == 'text' || elem[i].type == 'textarea') {
			url += '&' + elem[i].name + '=' + elem[i].value;
		}
		if(elem[i].type == 'select-one') {
			url += '&' + elem[i].name + '=';
			for(var j = 0;j<elem[i].options.length;j++) {
				if(elem[i].options[j].selected)
				{
					url += elem[i].options[j].value;
				}				
			}
		}
	}
		
	
	//alert(url);
	xmlHttp.open("GET",url,true);
	xmlHttp.send(null);
}

function removeFile(container,folder_ptr,mode,doc_type,folder_field,doc_field,case_id,report_name,doc_id) {
	xmlHttp=GetXmlHttpObject();
	if (xmlHttp==null) {
  		alert ("Your browser does not support AJAX!");
  		return;
	}
	
	xmlHttp.onreadystatechange=function() { 
        if (xmlHttp.readyState==4 || xmlHttp.readyState=="complete") 
        {
            if (xmlHttp.status==200 && xmlHttp.responseText == '1') 
            {
            	fileList(container,folder_ptr,mode,doc_type,folder_field,doc_field,case_id,report_name);	
            }
            	
        }
        
	}
	var url="%%[base_url]%%/documents.php";
	url=url+"?action=delete"; // Folder PTR
	url=url+"&doc_id="+doc_id; // doc_id
	//alert(url);
	xmlHttp.open("GET",url,true);
	xmlHttp.send(null);
}


function draw(container)
{
	var file_list_container = document.getElementById(container);
	
	// Parse the response text and append it as nodes
  var parser = new DOMParser();
  var doc = parser.parseFromString(xmlHttp.responseText, 'text/html');
  Array.from(doc.body.childNodes).forEach(function(node) {
    file_list_container.appendChild(node);
  });	
	return false; // to prevent user from following link href
}

function updateCurrentFolder(folder_field,folder_ptr)
{
	var folder_fields = document.getElementsByName(folder_field);
	//alert(folder_fields.length);
	if(folder_fields != null)
	{
		for(var i = 0;i<folder_fields.length;i++) {
			folder_fields[i].value = folder_ptr;
			//alert(folder_fields[i].name + ',' + folder_fields[i].value);
		}
	}
}

function updateCurrentDoc(document_field,doc_id)
{
	var document_fields = document.getElementsByName(document_field);
	if(document_fields != null)
	{
		for(var i = 0;i<document_fields.length;i++) {
			document_fields[i].value = doc_id;
			//alert(document_fields[i].name + ',' + document_fields[i].value);
		}
	}
	var radio_fields = document.getElementsByName('doc_id_radio');
	if(radio_fields != null)
	{
		for(var i = 0;i<radio_fields.length;i++) {
			radio_fields[i].checked = false;
			//alert(document_fields[i].name + ',' + document_fields[i].value);
		}
	}
}


function setDescription(file_id)
{
	var image = document.getElementById(file_id + "_pointer");
	var str = image.src;
	if (str.search(/pointer.gif/) > -1) {
		image.src = '%%[base_url]%%/images/pointer_down.gif';
	}else {
		image.src = '%%[base_url]%%/images/pointer.gif';
	}
	
	var div = document.getElementById(file_id + '_description');
	if(div.style.display == "none") {
		div.style.display = "block";
	} else {
		div.style.display = "none";
	}
}






