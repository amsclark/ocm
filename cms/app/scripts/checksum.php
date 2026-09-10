<?php

// CLI only. This file does its work at top level with no authentication check
// because the only assumed caller is cron or an operator with a shell -- but it
// sits under the document root, and Apache would run it for anyone who asked
// for the path. docker/apache.conf now denies /cms/app/ outright; this guard is
// the second lock, so the script stays safe under a vhost that lacks that rule.
if (PHP_SAPI !== 'cli' && PHP_SAPI !== 'phpdbg')
{
	header('HTTP/1.1 403 Forbidden');
	header('Content-Type: text/plain; charset=utf-8');
	error_log('Refused HTTP invocation of CLI script: ' . basename(__FILE__));
	die("This script is command-line only.\n");
}

function directory_checksum($directory_name)
{
	$dh = opendir($directory_name);
	
	while ($file = readdir($dh))
	{
		if ($file[0] != '.')
		{
			if (!is_dir("{$directory_name}/{$file}"))
			{
				echo md5_file("{$directory_name}/{$file}") . "  {$directory_name}/{$file}\n";			
			}
		}
	}
	
	closedir($dh);
}

$directories = array('subtemplates', 'templates', 'ops', 'modules');

foreach ($directories as $directory_name)
{
	directory_checksum($directory_name);
}

$dh = opendir('reports');

while ($file = readdir($dh))
{
	if ($file[0] != '.')
	{
		if (is_dir("reports/{$file}"))
		{
			directory_checksum("reports/{$file}");
		}
	}
}

closedir($dh);
?>