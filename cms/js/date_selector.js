function date_selector(field_name,container,month,year) {
	xmlHttp=GetXmlHttpObject();
	if (xmlHttp==null) {
  		alert ("Your browser does not support AJAX!");
  		return;
	}
	
	xmlHttp.onreadystatechange=function() { 
        if (xmlHttp.readyState==4 || xmlHttp.readyState=="complete") {
            if (xmlHttp.status==200) {
            	if(xmlHttp.responseText != null) {
            		drawCalendar(container);	
            	} else {
            		return false;
            	}
            	
            }
        }
	}
	var field_value = document.getElementById(field_name);
	var url="%%[base_url]%%/services/date_selector-server.php";
	url=url+"?field_name="+field_name;
	url=url+"&field_value="+field_value.value;
	url=url+"&month="+month;
	url=url+"&year="+year;
	url=url+"&container="+container;
	//alert(url);
	xmlHttp.open("GET",url,true);
	xmlHttp.send(null);
}

function openCalendar(field_name,container) 
{ 
	calendar_container = document.getElementById(container);
	if(calendar_container.style.display == "none") {
		calendar_container.style.display = "block";
		if (document.all && !window.opera && !window.XMLHttpRequest) 
		{
			calendar_container.style.position = "static";
		}
		date_selector(field_name,container);
	} else { closeCalendar(container); }
	
}

function closeCalendar(container) {
	calendar_container = document.getElementById(container);
	if(calendar_container.style.display == "block") {
		calendar_container.style.display = "none";
		calendar_container.innerHTML = null;	
	}
}

function drawCalendar(container)
{
	calendar_container = document.getElementById(container);

  var parser = new DOMParser();
  var doc = parser.parseFromString(xmlHttp.responseText, 'text/html');
  Array.from(doc.body.childNodes).forEach(function(node) {
    calendar_container.appendChild(node);
  });
	
}

function selectDate(field_name,date,container) {
	date_container = document.getElementById(field_name);
	date_container.value = date;
	date_container.focus();
	// Trigger the save reminder if on case tab
	if(typeof window.setConfirmUnload == 'function' && date_container.form.name == 'ws') { setConfirmUnload(true); }
	closeCalendar(container);
}