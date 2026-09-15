function calcDifference() {
	var theform = document.ws;
	if ((isNaN(parseFloat(theform.atty_fee_normal.value))) || (isNaN(parseFloat(theform.atty_fee_to_client.value)))) {
		return false;
	} else {
		var thediff = theform.atty_fee_normal.value - theform.atty_fee_to_client.value;
		theform.client_savings.value = thediff;
	}
}


function set_close()
{
	document.ws.close_date.value = "%%[current_date]%%";
	return false;
}

function set_ref_date()
{
	document.ws.referral_date.value = "%%[current_date]%%";
	return false;
}


document.ws.referral_date.focus();