<?php

function file_list($field_name = null, $field_value = null, $menu_array = null, $args = null, $data_array = null)
{
	// $server_name_and_port was assigned here, hard-coded to a Pika Software
	// development host. The only thing that read it was the ActiveX upload
	// block, which is gone, so it was left naming a third-party server in
	// every installation's source.
	
	if(!is_numeric($field_value))
	{
		$field_value = '0';
	}
	
	if (!is_array($data_array))
	{
		$data_array = array();
	}
	
	if(!is_array($args)) {
		$args = array();
	}
	
	$def_args = array(
		// STD Directives
		'doc_type' => 'C',
		'id' => $field_name,
		'folder_field' => $field_name . '_current_folder_id', // Stores current folder location (ex current folder_ptr)
		'doc_field' => $field_name . '_current_doc_id', // Stores current doc_id (ex current doc_id for forms)
		// Display Directives
		'folder_id_hidden' => false, // Hidden current_folder field (for folder selection)
		'doc_id_hidden' => false, // Hidden current doc_id field (for document selection)
		'div' => true,
		'width' => '305',
		'height' => '170',
		'class' => '',
		// Mode (edit/select/edit_select)
		'mode' => 'edit'
	);
	// Allow arg override
	$temp_args = pikaTempLib::getPluginArgs($def_args,$args);
	
	$case_id = $report_name = $id = '';
	//print_r($temp_args);
	switch ($temp_args['doc_type'])
	{
		case 'C':
			$doc_type_description = 'Case Files';
			if(isset($data_array['case_id']) && is_numeric($data_array['case_id']))
			{
				$case_id = $id = $data_array['case_id'];
			}
			break;
		case 'F':
			$doc_type_description = 'Forms';
			break;
		case 'R':
			$doc_type_description = 'Saved Reports';
			if(isset($data_array['report_name']) && strlen($data_array['report_name']) > 0)
			{
				$report_name = $id = $data_array['report_name'];
				
			}
			break;
		default:
			$doc_type_description = 'Files';
	}
	
	
	require_once('pikaSettings.php');
	$settings = pikaSettings::getInstance();
	$base_url = $settings['base_url'];
	$file_list_output = '';
	$file_list = $folder_list = '';
	
	
		
	
	
	$file_list_output .= "<table width=\"100%\" class=\"nopad\" cellspacing=\"0\" cellpadding=\"0\">";
	$file_list_output .= "<tr><th><a href=\"\" onClick=\"fileList('{$field_name}','0','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}','{$case_id}','{$report_name}');return false;\">{$doc_type_description}</a></th></tr><tr><td style='padding-left: 20px;padding-top: 3px;'>";
	
	require_once('pikaDocument.php');
	require_once('pikaUser.php');
	
	
	
	
	$docs_array = pikaDocument::getFiles($field_value,$temp_args['doc_type'],$id);
	$docs = $doc_types = array();
	
	// Document and folder names, file descriptions and the uploader's name are
	// all user-supplied -- an uploaded filename, a typed folder name, the
	// description typed on the file-edit form, and the first/middle/last/extra
	// columns the text_name plugin concatenates -- and every one of them was
	// interpolated straight into the markup below. That is a stored-XSS sink:
	// a file named `x<img src=x onerror=...>.txt` rendered as live HTML in the
	// documents tab of every case, form and saved-report screen that draws this
	// plugin. Escape each render through this helper.
	$h = function ($s)
	{
		return pl_html_escape($s);
	};
	foreach ($docs_array as $key => $file)
	{
		// Files		
		$user = new pikaUser($file['user_id']);
		$user_name = pikaTempLib::plugin('text_name','',$user->getValues());
		//print_r($docs_array);
		if($file['folder'] != 1)
		{
			$docs[$key]['li'] = "<a href=\"{$base_url}/documents.php?doc_id={$file['doc_id']}&action=download\" target=\"_blank\">" . $h($file['doc_name']) . "</a>&nbsp;";
		
		
		// Removed: an "[Edit Online]" affordance for Office mime types that
		// opened the document through
		// `new ActiveXObject('SharePoint.OpenDocuments.1').EditDocument(...)`
		// from an inline onclick, plus its
		// "[Online edits only available with Internet Explorer]" fallback text.
		// Unlike in later versions of this code, both halves were still live
		// here, not commented out, so this rendered a broken link and a
		// misleading message to every user on every supported browser.
		//
		// It is gone for good. ActiveX is an IE-only API that no supported
		// browser implements -- IE is end-of-life and Edge dropped ActiveX from
		// IE mode -- and the URL it built pointed at a hard-coded
		// dev0.pikasoftware.com host that has nothing to do with the
		// installation being used. The user-agent sniff it hung off read
		// $_SERVER['HTTP_USER_AGENT'] without checking the header was present,
		// which is a PHP notice on any request that omits it.
		//
		// The working path is untouched: the anchor built just above links
		// every file to documents.php?doc_id=...&action=download, which is how
		// these documents are actually opened.
		
			if(in_array($temp_args['mode'],array('select','edit_select')))
			{
				$number_pad = str_pad(rand(0,99999),5,'0');
				$uid = "form_id_" . $number_pad;
				/*$docs[$key]['li'] = "<input type=\"radio\" name=\"form_id_radio\" class=\"plradio\" id=\"{$uid}\" value=\"{$file['doc_id']}\" 
									onClick=\"updateCurrentDoc('{$temp_args['doc_field']}','{$file['doc_id']}');\" />
									<label for=\"{$uid}\">{$file['doc_name']}</label>&nbsp;";*/
				$docs[$key]['li'] = pikaTempLib::plugin('radio','form_id_radio',null,array($file['doc_id'] => $file['doc_name']),array("id={$uid}","onclick=updateCurrentDoc('{$temp_args['doc_field']}','{$file['doc_id']}');")) . "&nbsp;";
				//$docs[$key]['li'] = "<a href=\"\" onClick=\"updateCurrentDocument('{$temp_args['doc_field']}','{$file['doc_id']}');\">{$file['doc_name']}</a>&nbsp;";
			}
			$docs[$key]['li'] .= "<img id=\"{$file['doc_id']}_pointer\" title=\"More Info\" src='{$base_url}/images/pointer.gif' onClick='setDescription({$file['doc_id']})'>";
			
			$doc_size = pikaDocument::format_bytes($file['doc_size']);
			$description = array();
			$description['li_class'] = 'description';
			$description['li'] = "<div id='{$file['doc_id']}_description' name='{$file['doc_id']}_description' style='display: none'>";
			if(in_array($temp_args['mode'],array('edit','edit_select')))
			{
				$description['li'] .= 	"(<a href=\"\" onClick=\"editFile('{$field_name}','{$file['doc_id']}','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}');return false;\">Edit</a>
										|
										<a href=\"\" onClick=\"confirmDeleteFile('{$field_name}','{$file['folder_ptr']}','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}','{$case_id}','{$report_name}','{$file['doc_id']}');return false;\">Delete</a>
										)<br/>";
			}
			$description['li'] .= 	"Description: {$h($file['description'])}<br/>
									Created by: {$h($user_name)}&nbsp;({$doc_size})</div>";
									
						
			$docs[$key]['li'] .= pikaTempLib::plugin('ul','','',array($description),array('ul_class=pika_files'));
			$docs[$key]['li_class'] = "file";
			
			
		}
		
		// Folders
		elseif($file['folder'] == 1)
		{
			$docs[$key]['li'] = "<a onClick=\"fileList('{$field_name}','{$file['doc_id']}','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}','{$case_id}','{$report_name}');return false;\">" . $h($file['doc_name']) . "</a>&nbsp;";
			if($temp_args['mode'] != 'select')
			{
				$docs[$key]['li'] .= "<span class='folder_actions'>
									(<a href=\"\" onClick=\"editFile('{$field_name}','{$file['doc_id']}','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}');return false;\">Edit</a>
									|
									<a href=\"\" onClick=\"confirmDeleteFile('{$field_name}','{$file['folder_ptr']}','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}','{$case_id}','{$report_name}','{$file['doc_id']}');return false;\">Delete</a>
									)</span>";
			}	
			$docs[$key]['li_class'] = "directory";
		}
		
	}
	if(count($docs) > 0)
	{
		$file_list .= pikaTempLib::plugin('ul','','',$docs,array('ul_class=pika_files'));
	}
	
	
	$folder_array = pikaDocument::getParentFolders($field_value);
	
	if(count($folder_array))
	{
		foreach ($folder_array as $folder)
		{
			
			if($temp_args['mode'] != 'select')
			{
				$file_list= "<a onClick=\"fileList('{$field_name}','{$folder['doc_id']}','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}','{$case_id}','{$report_name}');\">" . $h($folder['doc_name']) . "</a>&nbsp;" .
							"<span class='folder_actions'>
							(<a href=\"\" onClick=\"editFile('{$field_name}','{$folder['doc_id']}','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}');return false;\">Edit</a>
							|
							<a href=\"\" onClick=\"confirmDeleteFile('{$field_name}','{$folder['folder_ptr']}','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}','{$case_id}','{$report_name}','{$folder['doc_id']}');return false;\">Delete</a>
							)</span>" . $file_list;
			}
			else 
			{
				$file_list= "<a onClick=\"fileList('{$field_name}','{$folder['doc_id']}','{$temp_args['mode']}','{$temp_args['doc_type']}','{$temp_args['folder_field']}','{$temp_args['doc_field']}','{$case_id}','{$report_name}');\">" . $h($folder['doc_name']) . "</a>&nbsp;" . $file_list;
			}
			$file_list = pikaTempLib::plugin('ul','','',array(array('li'=>$file_list,'li_class'=>'directory_open')),array('ul_class=pika_files'));
		}
		
	}
	
	$file_list_output .= $file_list;
	
	
	$file_list_output .= "</td></tr></table>";
	
	
	
	
	if($temp_args['div']) { // checklist contained in DIV
		// Both are pixel counts, so intval() is the whole check: it keeps a
		// caller from writing anything else into the style attribute.
		$width = '';
		if($temp_args['width']) 
		{
			$width = 'width:' . intval($temp_args['width']) . 'px;';
		}
		$height = '';
		if($temp_args['height']) 
		{
			$height = 'height:' . intval($temp_args['height']) . 'px;';
		}
		$class = '';
		if($temp_args['class']) 
		{
			$class = ' class="' . pl_html_escape($temp_args['class']) . '"';
		}
		
		// $div_id was only ever assigned inside the if, so a caller that
		// passed no id reached the interpolation below with the variable
		// undefined -- a warning in the page body on PHP 8.
		$div_id = '';
		if($temp_args['id'])
		{
			$div_id = ' id="' . pl_html_escape($temp_args['id']) . '"';
		}
		
		$file_list_output = "<div{$class}{$div_id} style=\"background-color:#FFFFFF;{$width}{$height}border:1px black solid;overflow:auto;\">"
							. $file_list_output . "</div>";
							
		if($temp_args['folder_id_hidden']) 
		{
			$file_list_output .= "\n";
			$file_list_output .= pikaTempLib::plugin('input_hidden',$temp_args['folder_field']);
		}
		if($temp_args['doc_id_hidden']) 
		{
			$file_list_output .= "\n";
			$file_list_output .= pikaTempLib::plugin('input_hidden',$temp_args['doc_field']);
		}
	}
	
	
	
	
	return $file_list_output;
}