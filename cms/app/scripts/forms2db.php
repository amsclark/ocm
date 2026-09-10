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

chdir('../../');

require_once('pika-danio.php');
pika_init();

require_once('pikaDocument.php');

set_time_limit(0);
ini_set('memory_limit','64M');

$i = 0;
$j = 0;
$k = 0;
$l = 0;

if(is_dir('forms'))
{
	forms2db('forms');
}

function forms2db ($directory_name,$parent_directory_id) 
{
	$dh = opendir($directory_name);
	while (($file = readdir($dh)) !== false) {
		
		if($file != '.' && $file != '..') {
			
			if(filetype($directory_name . '/' . $file) == 'dir')
			{
				
				$directory_obj = new pikaDocument();
				$directory_obj->folder = 1;
				if(is_numeric($parent_directory_id))
				{
					$directory_obj->folder_ptr = trim($parent_directory_id);
				}
				$directory_obj->mime_type = '';
				$directory_obj->doc_type = 'F';
				$directory_obj->doc_name = $file;
				$directory_obj->created = date('Y-m-d');
				$directory_obj->user_id = 999999;
				$directory_obj->save();
				echo "{$file} - DocID={$directory_obj->doc_id} - {$directory_name} Form Folder Created<br/>\n";
				forms2db($directory_name . '/' . $file,$directory_obj->doc_id);
			}
			else
			{
				$file_obj = new pikaDocument();
				$file_obj->doc_type = 'F';
				$file_obj->doc_name = $file;
				$file_obj->mime_type = 'application/octet-stream';
				$file_obj->user_id = 999999;
				$file_obj->created = date('Y-m-d');
				if(is_numeric($parent_directory_id))
				{
					$file_obj->folder_ptr = trim($parent_directory_id);
				}
				$content = file_get_contents($directory_name . '/' . $file);
				if(function_exists('mb_strlen')) {
					$doc_size = mb_strlen($content);
				} else {
					$doc_size = strlen($content);
				}
				$file_obj->doc_size = $doc_size;
				$file_obj->doc_data = addslashes(gzcompress($content,9));
				if(!isset($_ENV["PATH"]))
				{
					$exe_path = "c:/Pika/Cygwin/";
				}
				exec("{$exe_path}strings {$directory_name}/{$file}", $string_array);
				$contents_text = implode("\n", $string_array);
				$file_obj->doc_text = $contents_text;
				$file_obj->save();
				echo "{$file} - DocID={$file_obj->doc_id} - {$directory_name} Form Uploaded<br/>\n";
			}
		}
	}
}

?>
