
function setFunding(id) {
	
	xmlHttp=GetXmlHttpObject();
	if (xmlHttp==null) {
  		alert ("Your browser does not support AJAX!");
  		return;
	}
	
	xmlHttp.onreadystatechange=function() { 
        if (xmlHttp.readyState==4 || xmlHttp.readyState=="complete") {
            if (xmlHttp.status==200) {
            	if(xmlHttp.responseText != null) {
            		loadValues();	
            	} else {
            		return false;
            	}
            	
            }
        }
	}
	
	var url="%%[base_url]%%/services/cases-lookup-ajax.php";
	url=url+"?case_id="+id;
	xmlHttp.open("GET",url,true);
	xmlHttp.send(null);
}

function loadValues() 
{ 
	
	xmlDoc=xmlHttp.responseXML;
	funding_form = document.getElementById("funding");
	var funding = xmlDoc.getElementsByTagName("funding")[0];
	/*	cases-lookup-ajax.php answers with an empty <pikaCase/> when the
		caller may not read the case, so there is no <funding> element to
		read. Leave the field as the user left it. Without this guard the
		reads below throw and the rest of the page's scripts stop.
	*/
	if(funding_form == null || funding == null) {
		return;
	}
	if(funding_form.value == '') {
		if(funding.firstChild != null) {
			funding_form.value = funding.firstChild.nodeValue;
		}
	} else {
		if (funding_form.value != '' && funding.firstChild != null && funding_form.value != funding.firstChild.nodeValue){
			if (confirm('Would you like to update the funding code to match this new case?')){
				funding_form.value = funding.firstChild.nodeValue;	
			}
		}
	}
}


function set_fund(id)
{
	setFunding(id);
}