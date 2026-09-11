<?php

/***********************************/
/* Pika CMS (C) 2015 Pika Software */
/* http://pikasoftware.com         */
/***********************************/

require_once('pika-danio.php');
pika_init();

// Unconditional, not wrapped in a REQUEST_METHOD === 'POST' test like most
// of the other handlers, because this page dispatches a mutating action out
// of the query string: ?action=update runs
// UPDATE outcome_goals SET active = 0 before it reads the submitted list,
// so a request carrying no values deactivates every goal for the problem.
//
// pl_csrf_check() does two different jobs. On a POST it validates the
// per-session token. On any other method it falls through to
// pl_request_cross_site_verdict() and refuses a 'cross' verdict, which is
// the only defence a GET-dispatched write has. Wrapping the call in a POST
// test removes exactly that half.
//
// A typed URL, a bookmark and an emailed link all read as 'unknown' and are
// still allowed through, so this costs nothing a user would notice. See
// pl_csrf_check() in cms/app/lib/pl.php.
pl_csrf_check();
require_once('plFlexList.php');
require_once('pikaTempLib.php');
require_once('pikaMenu.php');


$base_url = pl_settings_get('base_url');
$main_html = array();

if (!pika_authorize("system", array()))
{
	$main_html['content'] = "Access denied";
	$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
						 <a href=\"{$base_url}site_map.php\">Site Map</a> &gt;
						 Menus";
	
	$default_template = new pikaTempLib('templates/default.html',$main_html);
	$buffer = $default_template->draw();
	pika_exit($buffer);
}

$action = pl_grab_get('action');
$outcome = pl_grab_get('outcome');
$value = pl_grab_get('value');
$old_value = pl_grab_get('old_value');
$menu_name = pl_grab_get('menu_name');
$field_list = pl_grab_get('field_list');

$numeric_types = array('tinyint','smallint','mediumint','int','bigint',
								'decimal','float','double','real',
								'bit','bool','serial');

$menu_yes_no = pikaTempLib::getMenu('yes_no');
$menu_enable_disable = array('0' => 'Enable', '' => 'Enable', '1' => 'Disable');

switch ($action)
{
	case 'edit':
	
		$outcome = DB::escapeString($outcome);
		$main_html['content'] = "<a href=\"{$base_url}/system-outcomes.php\">Return to Outcome Goals Listing</a>";
		$main_html['content'] .= "<form action=\"{$base_url}/system-outcomes.php?action=update&outcome={$outcome}\" method=\"POST\">";
		// Same as transfers.php: the update POST goes back to this file, which
		// enforces the token, so saving the goal list needs one in the body.
		$main_html['content'] .= pl_csrf_hidden_input();
		$main_html['content'] .= "<textarea name=\"values\" rows=\"18\" class=\"input-xxlarge\">";
		$sql = "SELECT * FROM outcome_goals WHERE active = 1 AND problem ";
		$sql .= " = '{$outcome}' ORDER BY outcome_goal_order ASC";
		$result = DB::query($sql);
		
		while ($row = DBResult::fetchRow($result))
		{
			$main_html['content'] .= "{$row['goal']}\n";
		}
		
		$main_html['content'] .= "</textarea><br><input type=\"submit\">\n";
		$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
							 <a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
							 <a href=\"{$base_url}/system-menus.php\">Menus</a> &gt;
							 Editing {$menu_name}";
		break;
		
	case 'update':
		require_once('pikaOutcomeGoal.php');
		
		$outcome = DB::escapeString(pl_grab_get('outcome'));
		$values = pl_grab_post('values');
		$new_goals = explode("\n",$values);
		$old_goals = array();
		
		/*	A print_r() of the submitted and the stored goal lists used to be
			echoed here, wrapped in a <pre>. It was left-over debugging: it
			printed the data to the browser, and because it wrote output
			before the header("Location: ...") at the end of this case, the
			redirect never fired and the admin was left looking at the dump
			instead of the edit screen.
		*/
		$sql = "SELECT * FROM outcome_goals WHERE problem='{$outcome}'";
		$result = DB::query($sql);
		
		while ($row = DBResult::fetchRow($result))
		{
			$old_goals[$row['outcome_goal_id']] = $row['goal'];
		}
		
		// This code should be moved to an object eventually.
		$sql = "UPDATE outcome_goals SET active = 0, outcome_goal_order = NULL WHERE problem='{$outcome}'";
		$result = DB::query($sql);
		$i = 0;
		
		foreach($new_goals as $goal)
		{
			$goal = trim($goal);
			
			if (strlen($goal) > 0)
			{
				$z = array_search($goal, $old_goals);
				
				if ($z !== false)
				{
					$g = new pikaOutcomeGoal($z);
				}
				
				else
				{
					$g = new pikaOutcomeGoal();
					$g->goal = $goal;
					$g->problem = $outcome;
				}
				
				$g->active = 1;
				$g->outcome_goal_order = $i++;
				$g->save();
			}
		}

		header("Location: {$base_url}/system-outcomes.php?action=edit&outcome={$outcome}");
		exit();		
		break;
		
	default:
	
		$main_html['content'] .= "<h2>Please select a Problem Code category to edit</h2><div class=\"span4\">";
		
		for ($i = 0; $i < 10; $i++)
		{
			$main_html['content'] .= "<a class=\"btn btn-block\" href=\"{$base_url}/system-outcomes.php?action=edit&outcome={$i}X\">{$i}0's</a><br>\n";
		}
		
		$problem_codes = pl_menu_get('problem_2008');
		
		foreach ($problem_codes as $key => $value)
		{
			$key = str_pad($key, 2, "0", STR_PAD_LEFT);
			$main_html['content'] .= "<a class=\"btn btn-block\" href=\"{$base_url}/system-outcomes.php?action=edit&outcome={$key}\">{$value}</a><br>\n";
		}

		$main_html['content'] .= "</div>";
		
		$main_html['nav'] = "<a href=\"{$base_url}\">Pika Home</a> &gt;
							 <a href=\"{$base_url}/site_map.php\">Site Map</a> &gt;
							 Menus";
		
		break;
}

$main_html['page_title'] = 'Outcomes Editor';
$default_template = new pikaTempLib('templates/default.html',$main_html);
$buffer = $default_template->draw();
pika_exit($buffer);

?>
