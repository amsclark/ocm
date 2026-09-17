function isEmpty(field)
{
	if ((field.value.length==0) || (field.value==null))
	{
		return true;
	}
	else
	{
		return false;
	}
}

$('.upload_control').change(function()
{
	$('#upload_gif').show("slow");
	$('#upload_form').submit();
});

/*
$(function () {
    $("#doc_upload").bind("click", function () {
        if (typeof ($("#doc_upload")[0].files) != "undefined") {
            $.each($("#doc_upload")[0].files, function(key, value) {
							var size = parseFloat($("#doc_upload")[0].files[0].size / 1024).toFixed(2);
            	alert(size + " KB.");
						});
        } else {
            // This browser does not support HTML5.
        }
    });
});
*/

var makeDocumentButtons = document.querySelectorAll('.js-case-docs-make-document');
for (var i = 0; i < makeDocumentButtons.length; i++)
{
	makeDocumentButtons[i].addEventListener('click', function (e)
	{
		if (isEmpty(this.form.elements.form_id))
		{
			alert('Please select a form.');
			e.preventDefault();
		}
	});
}

var debugLinks = document.querySelectorAll('.js-case-docs-debug');
for (var j = 0; j < debugLinks.length; j++)
{
	debugLinks[j].addEventListener('click', function ()
	{
		document.docgen.debug.value = 1;
		document.docgen.submit();
	});
}
