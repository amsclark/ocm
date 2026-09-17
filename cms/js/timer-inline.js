var timerID = null;
var timerRunning = false;

function round_extra(number,X)
{
	// rounds number to X decimal places, defaults to 2
    X = (!X ? 2 : X);
	return Math.round(number*Math.pow(10,X))/Math.pow(10,X);
}

function stopclock()
{
	if(timerRunning)
		clearTimeout(timerID);
    timerRunning = false;
}

function startclock()
{
	stopclock();
	showtime();
}

function showtime ()
{
	var now = new Date();
	var hours = now.getHours();
	var minutes = now.getMinutes();
    var seconds = now.getSeconds()
    var timeValue = "" + ((hours >12) ? hours -12 :hours)
	var elapsedValue = document.clock.elapsed_secs.value++;

    timeValue += ((minutes < 10) ? ":0" : ":") + minutes
	//timeValue += ((seconds < 10) ? ":0" : ":") + seconds
    timeValue += (hours >= 12) ? " PM" : " AM"

	document.clock.current.value = timeValue;
	document.clock.elapsed_mins.value = Math.round(elapsedValue/60);

    timerID = setTimeout(showtime,1000);
    timerRunning = true;
}

function currenttime ()
{
	var now = new Date();
	var hours = now.getHours();
	var minutes = now.getMinutes();
    var seconds = now.getSeconds()
    var timeValue = "" + ((hours >12) ? hours -12 :hours)

    timeValue += ((minutes < 10) ? ":0" : ":") + minutes
	// timeValue += ((seconds < 10) ? ":0" : ":") + seconds
    timeValue += (hours >= 12) ? " PM" : " AM"

	return timeValue;
}

document.addEventListener('DOMContentLoaded', function ()
{
	var links = document.querySelectorAll('.js-timer-highlight, .js-timer-pause-highlight');
	for (var i = 0; i < links.length; i++)
	{
		links[i].addEventListener('click', function (e)
		{
			e.preventDefault();
			toggleBox(this.getAttribute('data-target'), Number(this.getAttribute('data-mode')));
		});
	}
	if (document.clock)
	{
		document.clock.summary.focus();
		if (document.clock.getAttribute('data-timer-running') === '1')
		{
			startclock();
			document.clock.start.value = currenttime();
		}
		//-->
		//-->
	}
});

window.addEventListener('load', function ()
{
	if (document.querySelector('.js-timer-close'))
	{
		self.close();
	}
});
