document.ws.children.focus();
// 08-16-2012 - caw - fixed a bug where poverty was not displaying zero if amount is zero and there are persons helped
// 01-12-2012 - caw - modified function calc_poverty to correct error generated when more than 8 persons helped

<!-- // The second (non-adjusted) Income field needs to be calculated on each page view (it's not in the DB.)
income_change();
//-->

// rounds number to 2 decimal places
function round(rounding_number) 
{
	var v;

    // blank fields should not be rounded
    if (rounding_number == "")
	{
		return '';
	}

	// zero should be rounded off to 2 decimals
	if (rounding_number == 0)
	{
		return 0.00;
	}

	// v is the rounded value
	v = Math.round(rounding_number*100)/100;
	
	if (v == 0)
	{
		// v is either less than (+/-).01 or something strange has happened
		
		if (rounding_number > 0)
		{
			return "0.01";
		}
		
		else if (rounding_number < 0)
		{
			return "-0.01";
		}
		
		else
		{
			return "";
		}
	}
	
	else
	{
		return v;
	}
}


function str_to_wage(str)
{
	x = new String(str);
	var a = x.indexOf('x', 0);
	var b = x.indexOf('X', 0);
	var c = x.indexOf('*', 0);
	
	if (a > 0)
	{
		return round(x.substr(0, a) * str_to_wage(x.substr(a + 1, 100)));
	}
	
	else if (b > 0)
	{
		return round(x.substr(0, b) * str_to_wage(x.substr(b + 1, 100)));
	}

	else if (c > 0)
	{
		return round(x.substr(0, c) * str_to_wage(x.substr(c + 1, 100)));
	}

	else
	{
		return round(str);
	}
}


function annual_change()
{
	return true;
}

// AMW - 1-31-2012 - Added toFixed()s so currency values are formatted 
// correctly on screen after conversion.
function process_income(amt, interval)
{
	//alert(interval);
	//amt = str_to_wage(amt);
	
	if ('M' == interval)
	{
		return round(amt * 12).toFixed(2);
	}
	
	else if ('B' == interval)
	{
		return round(amt * 26).toFixed(2);
	}

	else if ('W' == interval)
	{
		return round(amt * 52).toFixed(2);
	}
	
	else if ('A' == interval)
	{
		return parseFloat(amt).toFixed(2);
	}
}

function calc_income()
{
	// AMW - 1-31-2012 - Added toFixed()s so currency values are formatted 
	// correctly on screen after conversion.
	if (document.ws.annual0.value != '')
	{
		//document.ws.annual0.value = str_to_wage(document.ws.annual0.value);

		if ('M' == document.ws.income_freq0.value)
		{
			document.ws.annual0.value = round(document.ws.annual0.value * 12).toFixed(2);
		}
		
		if ('B' == document.ws.income_freq0.value)
		{
			document.ws.annual0.value = round(document.ws.annual0.value * 26).toFixed(2);
		}
		
		if ('W' == document.ws.income_freq0.value)
		{
			document.ws.annual0.value = round(document.ws.annual0.value * 52).toFixed(2);
		}
		
		document.ws.income_freq0.value = 'A';
	}
	
	if (document.ws.annual1.value != '')
	{
		if ('M' == document.ws.income_freq1.value)
		{
			document.ws.annual1.value = round(document.ws.annual1.value * 12).toFixed(2);
		}
		
		if ('B' == document.ws.income_freq1.value)
		{
			document.ws.annual1.value = round(document.ws.annual1.value * 26).toFixed(2);
		}
		
		if ('W' == document.ws.income_freq1.value)
		{
			document.ws.annual1.value = round(document.ws.annual1.value * 52).toFixed(2);
		}
		
		document.ws.income_freq1.value = 'A';
	}
	
	if (document.ws.annual2.value != '')
	{
		if ('M' == document.ws.income_freq2.value)
		{
			document.ws.annual2.value = round(document.ws.annual2.value * 12).toFixed(2);
		}
		
		if ('B' == document.ws.income_freq2.value)
		{
			document.ws.annual2.value = round(document.ws.annual2.value * 26).toFixed(2);
		}
		
		if ('W' == document.ws.income_freq2.value)
		{
			document.ws.annual2.value = round(document.ws.annual2.value * 52).toFixed(2);
		}
		
		document.ws.income_freq2.value = 'A';
	}
	
	if (document.ws.annual3.value != '')
	{
		if ('M' == document.ws.income_freq3.value)
		{
			document.ws.annual3.value = round(document.ws.annual3.value * 12).toFixed(2);
		}
		
		if ('B' == document.ws.income_freq3.value)
		{
			document.ws.annual3.value = round(document.ws.annual3.value * 26).toFixed(2);
		}
		
		if ('W' == document.ws.income_freq3.value)
		{
			document.ws.annual3.value = round(document.ws.annual3.value * 52).toFixed(2);
		}
		
		document.ws.income_freq3.value = 'A';
	}
	
	if (document.ws.annual4.value != '')
	{
		document.ws.annual4.value = process_income(document.ws.annual4.value, 
													document.ws.income_freq4.value);
		
		document.ws.income_freq4.value = 'A';
	}
	
	if (typeof(document.ws.annual5) !== "undefined") 
	{	
		if (document.ws.annual5.value != '')
		{
			document.ws.annual5.value = process_income(document.ws.annual5.value, 
														document.ws.income_freq5.value);
			document.ws.income_freq5.value = 'A';
		}
	}

	if (typeof(document.ws.annual6) !== "undefined") 
	{	
		if (document.ws.annual6.value != '')
		{
			document.ws.annual6.value = process_income(document.ws.annual6.value, 
														document.ws.income_freq6.value);
			document.ws.income_freq6.value = 'A';
		}
	}
	
	if (typeof(document.ws.annual7) !== "undefined") 
	{	
		if (document.ws.annual7.value != '')
		{
			document.ws.annual7.value = process_income(document.ws.annual7.value, 
														document.ws.income_freq7.value);
			document.ws.income_freq7.value = 'A';
		}
	}
	
	income_change();
}

function income_change()
{
	// if a weekly was changed
	var i;
	var total;
	
	total = null;

	// use round() otherwise total will be a string
	if (document.ws.annual0.value != '')
	{
		total += round(document.ws.annual0.value);
		document.ws.income_freq0.value = 'A';
	}

	if (document.ws.annual1.value != '')
	{
		total += round(document.ws.annual1.value);
		document.ws.income_freq1.value = 'A';
	}
	
	if (document.ws.annual2.value != '')
	{
		total += round(document.ws.annual2.value);
		document.ws.income_freq2.value = 'A';
	}

	if (document.ws.annual3.value != '')
	{
		total += round(document.ws.annual3.value);
		document.ws.income_freq3.value = 'A';
	}

	if (document.ws.annual4.value != '')
	{
		total += round(document.ws.annual4.value);
		document.ws.income_freq4.value = 'A';
	}

	if (typeof(document.ws.annual5) !== "undefined") 
	{	
	if (document.ws.annual5.value != '')
	{
		total += round(document.ws.annual5.value);
		//document.ws.income_freq5.value = 'A';
	}
	}
	
	if (typeof(document.ws.annual6) !== "undefined") 
	{	
		if (document.ws.annual6.value != '')
		{
			total += round(document.ws.annual6.value);
			//document.ws.income_freq4.value = 'A';
		}
	}

	if (typeof(document.ws.annual7) !== "undefined") 
	{	
		if (document.ws.annual7.value != '')
		{
			total += round(document.ws.annual7.value);
			//document.ws.income_freq4.value = 'A';
		}
	}
	
// 08-16-2012 - caw - added the if in case total is null
	if(total != null)	
		// AMW - 1-31-2012 - I added toFixed.
		document.ws.income.value = total.toFixed(2);
	else
		document.ws.income.value = total;	

// 08-16-2012 - caw - modified so starting value is blank and not 0.00	
//	total = 0.00;
	total = null;
	
// 08-16-2012 - caw - modified so testing if greater than or equal to zero			
	// now get sum of only income sources
	if (document.ws.annual0.value >= 0 && document.ws.annual0.value != '')
		total += round(document.ws.annual0.value);

	if (document.ws.annual1.value >= 0 && document.ws.annual1.value != '')
		total += round(document.ws.annual1.value);

	if (document.ws.annual2.value >= 0 && document.ws.annual2.value != '')
		total += round(document.ws.annual2.value);

	if (document.ws.annual3.value >= 0 && document.ws.annual3.value != '')
		total += round(document.ws.annual3.value);

	if (document.ws.annual4.value >= 0 && document.ws.annual4.value != '')
		total += round(document.ws.annual4.value);

	if (typeof(document.ws.annual5) !== "undefined") 
	{	
		if (document.ws.annual5.value >= 0 && document.ws.annual5.value != '')
			total += round(document.ws.annual5.value);
	}
	
	if (typeof(document.ws.annual6) !== "undefined") 
	{	
		if (document.ws.annual6.value >= 0 && document.ws.annual6.value != '')
			total += round(document.ws.annual6.value);
	}

	if (typeof(document.ws.annual7) !== "undefined") 
	{	
		if (document.ws.annual7.value >= 0 && document.ws.annual7.value != '')
			total += round(document.ws.annual7.value);
	}

// 08-16-2012 - caw - added the if in case total is null
	if(total != null)	
	// AMW - 1-26-2012 - I removed the call to round() because it was giving
	// you a blank field, and not a zero, if Gross Income was zero.
	// AMW - 1-31-2012 - I added toFixed.
		document.ws.income_only.value = total.toFixed(2);
	else
		document.ws.income_only.value = total;	
}

function asset_change()
{
	var total = null;
	
	if(isNumeric(document.ws.asset0.value))
	{
		document.ws.asset0.value = parseFloat(document.ws.asset0.value).toFixed(2);
		total = total + parseFloat(document.ws.asset0.value);
	}
	if(isNumeric(document.ws.asset1.value))
	{
		document.ws.asset1.value = parseFloat(document.ws.asset1.value).toFixed(2);
		total = total + parseFloat(document.ws.asset1.value);
	}
	if(isNumeric(document.ws.asset2.value))
	{
		document.ws.asset2.value = parseFloat(document.ws.asset2.value).toFixed(2);
		total = total + parseFloat(document.ws.asset2.value);
	}
	if(isNumeric(document.ws.asset3.value))
	{
		document.ws.asset3.value = parseFloat(document.ws.asset3.value).toFixed(2);
		total = total + parseFloat(document.ws.asset3.value);
	}
	if(isNumeric(document.ws.asset4.value))
	{
		document.ws.asset4.value = parseFloat(document.ws.asset4.value).toFixed(2);
		total = total + parseFloat(document.ws.asset4.value);
	}

	document.ws.assets.value = total;
	if(isNumeric(total))
	{
		document.ws.assets.value = total.toFixed(2);	
	}
	
}

function ph_change()
{
	if (document.ws.adults.value == '' && document.ws.children.value == '')
	{
		document.ws.persons_helped.value = '';
	}
	
	else
	{
		// use a Math. function otherwise total will be a string
		document.ws.persons_helped.value = Math.ceil(document.ws.adults.value) + Math.ceil(document.ws.children.value);
	}
}

function calc_poverty()
{
	var percent = 0;
	var povtmp = 0;
	var g = new Array();

	/*	The menu value is written straight into the source of this file, so a
		guideline typed with a thousands separator - "5,680", which is how the
		federal table prints it - became the JavaScript comma operator:
		g[0] = 5,680 assigned 680. Every household size then measured against
		one eighth of the real figure. Quote the tag so the value arrives as a
		string, take the commas out, and read it as a base-10 integer.
	*/
	g[0] = parseInt((""+"%%[0,menu_poverty,text_menu]%%").replace(/,/g, ''), 10);
	g[1] = parseInt((""+"%%[1,menu_poverty,text_menu]%%").replace(/,/g, ''), 10);
	g[2] = parseInt((""+"%%[2,menu_poverty,text_menu]%%").replace(/,/g, ''), 10);
	g[3] = parseInt((""+"%%[3,menu_poverty,text_menu]%%").replace(/,/g, ''), 10);
	g[4] = parseInt((""+"%%[4,menu_poverty,text_menu]%%").replace(/,/g, ''), 10);
	g[5] = parseInt((""+"%%[5,menu_poverty,text_menu]%%").replace(/,/g, ''), 10);
	g[6] = parseInt((""+"%%[6,menu_poverty,text_menu]%%").replace(/,/g, ''), 10);
	g[7] = parseInt((""+"%%[7,menu_poverty,text_menu]%%").replace(/,/g, ''), 10);
	g[8] = parseInt((""+"%%[8,menu_poverty,text_menu]%%").replace(/,/g, ''), 10);
	
	calc_income();

	if (document.ws.persons_helped.value == '' || document.ws.persons_helped.value == 0)
	{
		document.ws.poverty.value = '';
		document.ws.poverty_income_only.value = '';
		
		return;
	}

	if (document.ws.persons_helped.value > 8)
	{
		povtmp = g[8] + (g[0] * (document.ws.persons_helped.value - 8));
	}
	
	else
	{
		povtmp = g[document.ws.persons_helped.value];
	}
	
// 08-16-2012 - caw - rearranged if statement to evaluate if empty first
	if (document.ws.income.value == '')
	{
		document.ws.poverty.value = '';
	}
	
// 08-16-2012 - caw  - changed to test for zero instead of text zero
// else if (document.ws.income.value == '0')	
	else if (document.ws.income.value == 0)
	{
		document.ws.poverty.value = round('0');
	}
	else
	{
		percent = document.ws.income.value / povtmp;
		document.ws.poverty.value = round(percent * 100);
	}

// 08-16-2012 - caw - changed to test for zero instead of text zero
//	if (document.ws.income_only.value == '0')
	if (document.ws.income_only.value == 0)
	{
		document.ws.poverty_income_only.value = round('0');
	}
	else if (document.ws.income_only.value == '')
	{
		document.ws.poverty_income_only.value = '';
	}
	else
	{
		// 01-12-2012 - caw - modified to correct error when more than 8 persons helped
		percent = document.ws.income_only.value / povtmp;
		document.ws.poverty_income_only.value = round(percent * 100);
	}
	
	return;
}

function calcWage()
{
	document.ws.dontuse3.value = document.ws.dontuse1.value * document.ws.dontuse2.value;
}

function sendToGrid()
{
	if (document.ws.annual0.value == '')
	{
		document.ws.annual0.value = document.ws.dontuse3.value;
		document.ws.income_freq0.value = 'W';
	}
	
	else if (document.ws.annual1.value == '')
	{
		document.ws.annual1.value = document.ws.dontuse3.value;
		document.ws.income_freq1.value = 'W';
	}
	
	else if (document.ws.annual2.value == '')
	{
		document.ws.annual2.value = document.ws.dontuse3.value;
		document.ws.income_freq2.value = 'W';
	}
	
	else if (document.ws.annual3.value == '')
	{
		document.ws.annual3.value = document.ws.dontuse3.value;
		document.ws.income_freq3.value = 'W';
	}
	
	else if (document.ws.annual4.value == '')
	{
		document.ws.annual4.value = document.ws.dontuse3.value;
		document.ws.income_freq4.value = 'W';
	}
	
// 08-15-2012 - caw - modified to account for additional income rows
	else if (document.ws.annual5.value == '')
	{
		document.ws.annual5.value = document.ws.dontuse3.value;
		document.ws.income_freq5.value = "W";
	}	
	
	else if (document.ws.annual6.value == '')
	{
		document.ws.annual6.value = document.ws.dontuse3.value;
		document.ws.income_freq6.value = "W";
	}
	
	else if (document.ws.annual7.value == '')
	{
		document.ws.annual7.value = document.ws.dontuse3.value;
		document.ws.income_freq7.value = "W";
	}
	
	else
	{
		alert('Sorry, no room for additional income sources.');
	}

	return;
}

// 20121108 MDF - Fix to Assets

function isNumeric(possibleNumber) 
{
	if(possibleNumber == null || possibleNumber.length == 0)
	{
		return false;
	}
	var validChars = '0123456789.';
	for(var i = 0; i < possibleNumber.length; i++) 
	{
		if(validChars.indexOf(possibleNumber.charAt(i)) == -1)
		{
			return false;
		}
	}
	return true;
}