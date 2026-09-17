document.addEventListener('DOMContentLoaded', function ()
{
				new Sortable(example2Left, {
					group: 'shared', // set both lists to same group
					animation: 150,
					onSort: function(event, ui) {
						var sorted = this.toArray();
						document.getElementById('screen_fields').value = sorted;
						}
				});

				new Sortable(example2Right, {
					group: 'shared',
				animation: 150

				});
});
