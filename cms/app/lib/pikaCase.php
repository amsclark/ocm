<?php

/**********************************/
/* Pika CMS (C) 2002 Aaron Worley */
/* http://pikasoftware.com        */
/**********************************/

require_once('plBaseWithUdf.php');

/**
* Something.
*
* @author Aaron Worley <amworley@pikasoftware.com>;
* @version 1.0
* @package Danio
*/
class pikaCase extends plBaseWithUdf
{
	private $contacts = array();
	private $attorneys = array();
	private $activities = array();
	private $docs = array();
	private $compens = array();
	
	
	
	public function __construct($case_id = null)
	{
		global $auth_row;		
		$autonumber_on_new_case = pl_settings_get('autonumber_on_new_case');
		$this->db_table = 'cases';

		parent::__construct($case_id);

		if (is_null($case_id)) 
		{
			// MySQL 4.1+ will accept the old TIMESTAMP syntax, so use that.
			$this->setValue('created', date('YmdHis'));
			$this->setValue('office', $_SESSION['def_office']);
			$this->setValue('intake_user_id', $auth_row['user_id']);
			
			if (strlen((string) $this->getValue('open_date')) < 1)
			{
				$this->setValue('open_date', date('Y-m-d'));
			}
			
			if (strlen((string) $this->getValue('intake_type')) < 1)
			{
				$this->setValue('intake_type', $_SESSION['def_intake_type']);
			}
			
		}
		
		// other stuff
		if ((true == $autonumber_on_new_case && is_null($case_id)) || 'auto' == $this->getValue('number'))
		{
			$this->generateCaseNumber();
		}
		
		
		return true;
	}
	
	public function setValue($value_name, $value)
	{
		if ('number' == $value_name && 'auto' == $value)
		{
			$this->generateCaseNumber();
		}
		
		// Don't allow the close date to occur before the open date.
		else if ('close_date' == $value_name) 
		{
			if (strlen($value) < 1 || (strlen($this->values['open_date']) < 1 && strlen($value) < 1))
			{
				parent::setValue($value_name, $value);
			}
			elseif (strlen($this->values['open_date']) > 0 && strtotime($value) >= strtotime($this->values['open_date'])) 
			{
				parent::setValue($value_name, $value);	
			}
			
		}
		
		else if ('outcome_goals' == $value_name)
		{
			// AMW - Do nothing.  I decided it will be more consistant to handle
			// outcomes by adding new methods to pikaCase.  I could have processed
			// them here by extracting the data from the array, but no other
			// data are passed as an array so methods will better match
			// existing conventions.
		}
		
		else 
		{
			parent::setValue($value_name, $value);
		}
	}
	
	
	protected function snapshotClientDataColumn($column, $v)
	{
		//echo $column;
		$case_val = $this->getValue('case_' . $column);
		
		if ($case_val === null || $case_val == '')
		{
			//echo "snapshot triggered";
						
			if (strlen($v) > 0)
			{
				//echo $column . "=" . $v . " ";
				$this->setValue('case_' . $column, $v);
				$this->save();
			}
		}
	}
	/**
	* Add a contact to a case.
	*
	* $c can be a pikaContact object or the contact's ID number.
	* $role is the relation_code describing the contact's relationship to the case.
	*
	* @return boolean
	* @param mixed $c
	* @param integer $role
	*/
	public function addContact($c, $role)
	{
		$contact_id = null;
		$conflict_id = pl_mysql_next_id('conflict');
		
		if (is_object($c))
		{
			if (!isset($c->contact_id))
			{
				trigger_error('Passed object is not a pikaContact: ' . get_class($c));
				return false;
			}
			
			$contact_id = $c->contact_id;
		}
		
		else if (is_numeric($c) && $c > 0)
		{
			$contact_id = $c;
		}
		
		else 
		{
			trigger_error('Passed value is not a valid Contact');
			return false;
		}
		
		/*	Now that all the variables are determined, save the new contact to the db
		and to this object.
		*/
		$case_id = $this->getValue('case_id');
		
		/*	$role reaches here straight from the caller and was not checked
			at all. ops/add_case_contact.php and ops/add_case_new_contact.php
			pass pl_grab_post('relation_code'), and pl_clean_form_input()
			encodes only < and >, so a quote arrived intact and closed this
			string early. A POST of
			
				relation_code=2'),('88888888','7','7','9
			
			appended a second VALUES tuple, which links any contact to any
			case in the table the conflict-of-interest check reads. The same
			value also arrives unfiltered from services/transfer_case.php
			(a payload from another instance) and from pikaLSXML_V2 (an
			uploaded XML import). The contact id is already constrained by
			the is_numeric() test above; the cast is belt and braces.
		*/
		$safe_role = DB::escapeString($role);
		$safe_contact_id = (int) $contact_id;
		$sql = "INSERT INTO conflict (conflict_id, contact_id, case_id, relation_code)
					VALUES ('{$conflict_id}', '{$safe_contact_id}', '{$case_id}', '{$safe_role}')";
		DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		$this->contacts[$contact_id] = $role;
		
		// Update the conflict of interest information.
		$this->resetConflictStatus();
		
		// If this is the first client for this case, make them the primary client and set age, county, ZIP code fields
		if (1 == $role)
		{
			$sql = "SELECT birth_date, open_date, city, state, county, zip 
								FROM conflict 
								LEFT JOIN cases ON conflict.case_id=cases.case_id
								LEFT JOIN contacts ON conflict.contact_id=contacts.contact_id 
								WHERE conflict.case_id={$case_id} AND relation_code='1'";
			$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
			
			if (DBResult::numRows($result) == 1)
			{
				$this->setValue('client_id', $contact_id);
				$row = DBResult::fetchRow($result);
				
				if ($row['birth_date'] && $row['open_date'])
				{
					$this->setValue('client_age', pl_calc_age($row['birth_date'], $row['open_date']));
				}
				
				if ($row['zip'])
				{
				//	$this->setValue('case_zip', $row['zip']);
				}
				
				if ($row['county'])
				{
				//	$this->setValue('case_county', $row['county']);
				}
				
				if ($row['city'])
				{
					$this->setValue('case_city', $row['city']);
				}
								
				if ($row['state'])
				{
					$this->setValue('case_state', $row['state']);
				}
			}
		}
		
		$this->save();		
		// TODO: optimize by merging the 2 cases UPDATEs
		return true;
	}
	
	/**
	 * Runs the primary conflict check against all case contacts.
	 *
	 * If a potential conflict is found, the poten_conflicts value is set to 1.
	 * Otherwise it is set to 0.  If the '$reset_verification' argument is
	 * 'true', then the case's conflicts value is set to NULL, meaning the user
	 * will be prompted to re-affirm whether a case has conflicts or not.
	 *
	 * @return boolean
	 * @param boolean $reset_verification
	*/
	public function resetConflictStatus($reset_verification = true)
	{
		// New method: use secondary conflict checks in addition to primary conflict check.
		$potentials = $this->fuzzyConflictCheck();
		$tally = sizeof($potentials);

		if ($tally > 0)
		{
			$this->setValue('poten_conflicts', 1);
		}
		
		else
		{
			$this->setValue('poten_conflicts', '0');
		}
		
		if ($reset_verification)
		{
			$this->setValue('conflicts', null);
		}
		
		$this->save();			
		return $this->getValue('poten_conflicts');
	}
	
	
	// describe contacts?  getContactsArray?
	public function getContactsDb()
	{
		$sql = "SELECT	conflict_id, 
						conflict.case_id, 
						conflict.relation_code, 
						menu_relation_codes.label as role,
						contacts.* 
				FROM conflict
				LEFT JOIN contacts ON conflict.contact_id = contacts.contact_id
				LEFT JOIN menu_relation_codes ON conflict.relation_code = menu_relation_codes.value
				WHERE conflict.case_id = '{$this->values['case_id']}'
				ORDER BY menu_relation_codes.value ASC, last_name ASC, first_name ASC, extra_name ASC, middle_name ASC";
		$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		return $result;
	}
	
	
	public function getNotes($order = 'ASC', $list_length = 50, $first_row = 0, &$row_count = NULL, &$total_hours = NULL)
	{
		$clean_order = pl_safe_sort_direction($order);
		//$clean_first_row = mysql_real_escape_string($first_row);
		//$clean_list_length = mysql_real_escape_string($list_length);
		
		$sql = "SELECT COUNT(*) AS count
				FROM activities
				WHERE case_id='{$this->values['case_id']}';";
		
		$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		$row = DBResult::fetchRow($result);
		$row_count = $row['count'];
		
		$sql = "SELECT SUM(hours) AS hours
				FROM activities
				WHERE case_id='{$this->values['case_id']}'
				AND completed = '1';";
		
		$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		$row = DBResult::fetchRow($result);
		$total_hours = $row['hours'];
		
		$sql = "SELECT activities.*,
							users.first_name, 
							users.last_name
				FROM activities
				LEFT JOIN users ON activities.user_id=users.user_id
				WHERE case_id='{$this->values['case_id']}'
				ORDER BY act_date {$clean_order}, act_time {$clean_order}, last_changed {$clean_order}";
		if ($first_row && $list_length){
			$sql .= " LIMIT " . (int) $first_row . ", " . (int) $list_length;
		} elseif ($list_length){
			$sql .= " LIMIT " . (int) $list_length;
		}
		$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		return $result;
	}
	
	public function makeClientDataSnapshot($primary_client)
	{
		$this->snapshotClientDataColumn('address', $primary_client->address);
		$this->snapshotClientDataColumn('address2', $primary_client->address2);
		$this->snapshotClientDataColumn('city', $primary_client->city);
		$this->snapshotClientDataColumn('state', $primary_client->state);
		$this->snapshotClientDataColumn('zip', $primary_client->zip);
		$this->snapshotClientDataColumn('county', $primary_client->county);
		
		// It would be more efficient to run $this->save here, but the changes
		// don't actually get saved.
	}
	

	protected function generateCaseNumber()
	{
		// Handle custom templates.
		if (file_exists(pl_custom_directory() . "/modules/autonumber.php")) {
			require_once(pl_custom_directory() . '/modules/autonumber.php');
		} else {
			require_once('modules/autonumber.php');	
		}
		
		$new_case_no = autonumber($this->getValues());
		
		// Before proceeding, make certain that this case number does not already exist.
		$clean_new_case_no = DB::escapeString($new_case_no);
		$sql = "SELECT count(*) AS tally FROM cases WHERE number = '{$clean_new_case_no}'";
		$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		$row = DBResult::fetchRow($result);
		
		if ($row['tally'] > 0) 
		{
			$new_case_no = null;
		}
		
		$this->setValue('number', $new_case_no);
	}
	
	
	public function save()
	{
		if ($this->is_modified) 
		{
			parent::setValue('last_changed', null);
			//$this->last_changed = null;
		}
		
		parent::save();
	}
	
	
	
	public function delete()
	{
		require_once('pikaDocument.php');
		
		// Delete conflict records.
		$sql = "DELETE FROM conflict WHERE case_id = '{$this->case_id}'";
		DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		
		// Delete documents.
		$sql = "DELETE FROM doc_storage WHERE 1 AND case_id = '{$this->case_id}';";
		DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		
		// Clean up orphaned activities
		$sql = "UPDATE activities SET case_id = NULL WHERE 1 AND case_id = '{$this->case_id}';";
		DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		parent::delete();
	}

	
	/*	Conflict of interest check for this case.
		
		Every value below is read out of a table rather than out of the request,
		which is not the same thing as safe. aliases.ssn is a free-text column an
		intake user fills in, eleven characters wide, and nothing checks its
		shape: "1' OR 1=1#" fits. It went into the two statements in the social
		security block as text, so one saved contact record turned this check
		into a statement of that user's choosing. On a test install it listed
		every contact in the database - including people with no social security
		number at all - as an SSN conflict. Bind every value.
		
		Further faults in the same function, all of them under-reporting:
		
		The social security test read strlen($row['ssn'] > 0). That measures the
		comparison, not the number, so it answered 1 for very nearly every value.
		Count digits instead: an intake that carries "XXX-XX-XXXX" or "N/A" as a
		placeholder must not match every other record holding the same
		placeholder.
		
		The name block and the social security block each built two statements
		and assigned both to $sql, so the first of each pair - the one that reads
		the contacts table - was thrown away before it ran. A contact written by
		a data migration or another ingest path can have no aliases row at all,
		and a conflict with that person was never reported. Both statements now
		run. The discarded pair also named aliases.mp_first in a statement that
		does not join aliases, so neither could have run as written.
		
		An empty mp_last matches every alias that has no metaphone key, which is
		every organisation and every part-filled record, so the name search is
		skipped when there is no key to search on.
		
		cms/app/extralib/lib/pikaCms.php carries a second copy of this check, the
		one cms/reports/conflict/conflict.php uses. The two files cannot share
		one implementation because pika_cms.php does not put app/lib on the
		include path, so a fix here needs the same fix there.
	*/
	public function fuzzyConflictCheck($lim = 10)
	{
		$case_id = (int) $this->getValue('case_id');
		$lim = (int) $lim;
		$conflict_array = array();
		$seen = array();
		
		if ($case_id < 1 || $lim < 1)
		{
			return $conflict_array;
		}
		
		/*	contacts is joined on conflict.contact_id, not on aliases.contact_id.
			A party with no aliases row left the aliases side of the join NULL,
			which left aliases.contact_id NULL, which left the contacts side
			NULL as well - so that party carried no name, no social security
			number and no date of birth into the searches below and was checked
			by contact ID alone. COALESCE reads the aliases values when the
			party has an aliases row, which is the normal case, and the contacts
			values when it does not.
		*/
		$sql = "SELECT conflict.contact_id, relation_code,
					COALESCE(aliases.mp_first,contacts.mp_first) AS mp_first,
					COALESCE(aliases.mp_last,contacts.mp_last) AS mp_last,
					COALESCE(aliases.ssn,contacts.ssn) AS ssn,
					contacts.birth_date
				FROM conflict
				LEFT JOIN aliases ON conflict.contact_id=aliases.contact_id
				LEFT JOIN contacts ON conflict.contact_id=contacts.contact_id
				WHERE case_id = ?";
		$result = DB::preparedQuery($sql,array($case_id))
			or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		
		/*	Read the parties out before searching. The searches below run on the
			same connection, and starting one while this result is still open
			loses this result.
		*/
		$parties = array();
		
		while ($row = DBResult::fetchRow($result))
		{
			$parties[] = $row;
		}
		
		foreach ($parties as $row)
		{
			$relation_code = $row['relation_code'];
			$contact_id = $row['contact_id'];
			$mp_first = (string) $row['mp_first'];
			$mp_last = (string) $row['mp_last'];
			$ssn = (string) $row['ssn'];
			$birth_date = $row['birth_date'];
			
			// Match by contact ID
			$sql = "SELECT conflict.*, contacts.*, number, cases.case_id, problem, status, label AS role
					FROM conflict
					LEFT JOIN contacts ON conflict.contact_id=contacts.contact_id
					LEFT JOIN cases ON conflict.case_id=cases.case_id
					LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
					WHERE relation_code != ?
					AND conflict.contact_id = ?
					LIMIT {$lim}";
			self::collectConflicts($sql,array($relation_code,$contact_id),'ID',
				$conflict_array,$seen);
			
			// Match by metaphone name and birth date
			if (strlen($mp_last) > 0)
			{
				$contacts_clause = '';
				$aliases_clause = '';
				$contacts_params = array($relation_code,$mp_last);
				$aliases_params = array($relation_code,$mp_last);
				
				if (strlen($mp_first) > 0)
				{
					$contacts_clause .= ' AND contacts.mp_first = ?';
					$aliases_clause .= ' AND aliases.mp_first = ?';
					$contacts_params[] = $mp_first;
					$aliases_params[] = $mp_first;
				}
				
				if ($birth_date)
				{
					$contacts_clause .= ' AND (contacts.birth_date = ? OR contacts.birth_date IS NULL)';
					$aliases_clause .= ' AND (contacts.birth_date = ? OR contacts.birth_date IS NULL)';
					$contacts_params[] = $birth_date;
					$aliases_params[] = $birth_date;
				}
				
				$contacts_params[] = $contact_id;
				$aliases_params[] = $contact_id;
				
				$sql = "SELECT conflict.*, contacts.*, number, cases.case_id, problem, status, label AS role
						FROM contacts
						LEFT JOIN conflict ON contacts.contact_id=conflict.contact_id
						LEFT JOIN cases ON conflict.case_id=cases.case_id
						LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
						WHERE relation_code != ? AND contacts.mp_last = ?{$contacts_clause}
						AND conflict.contact_id != ?
						LIMIT {$lim}";
				self::collectConflicts($sql,$contacts_params,'NAME',$conflict_array,$seen);
				
				$sql = "SELECT conflict.*, contacts.*, number, cases.case_id, problem, status, label AS role
						FROM aliases
						LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id
						LEFT JOIN conflict ON aliases.contact_id=conflict.contact_id
						LEFT JOIN cases ON conflict.case_id=cases.case_id
						LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
						WHERE relation_code != ? AND aliases.mp_last = ?{$aliases_clause}
						AND conflict.contact_id != ?
						LIMIT {$lim}";
				self::collectConflicts($sql,$aliases_params,'NAME',$conflict_array,$seen);
			}
			
			// Match by social security number
			if (strlen(preg_replace('/\D/','',$ssn)) > 0)
			{
				$ssn_params = array($relation_code,$ssn,$contact_id,$mp_last);
				
				$sql = "SELECT conflict.*, contacts.*, number, cases.case_id, problem, status, label AS role
						FROM contacts
						LEFT JOIN conflict ON contacts.contact_id=conflict.contact_id
						LEFT JOIN cases ON conflict.case_id=cases.case_id
						LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
						WHERE relation_code != ? AND contacts.ssn = ?
						AND conflict.contact_id != ? AND contacts.mp_last != ?
						LIMIT {$lim}";
				self::collectConflicts($sql,$ssn_params,'SSN',$conflict_array,$seen);
				
				$sql = "SELECT conflict.*, contacts.*, number, cases.case_id, problem, status, label AS role
						FROM aliases
						LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id
						LEFT JOIN conflict ON aliases.contact_id=conflict.contact_id
						LEFT JOIN cases ON conflict.case_id=cases.case_id
						LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
						WHERE relation_code != ? AND aliases.ssn = ?
						AND conflict.contact_id != ? AND aliases.mp_last != ?
						LIMIT {$lim}";
				self::collectConflicts($sql,$ssn_params,'SSN',$conflict_array,$seen);
			}
		}
		
		return $conflict_array;
	}
	
	
	/*	Run one conflict search and add what it returns to $conflict_array.
		
		A person can be reached through more than one party on this case, and now
		through more than one statement per search, so each match type is listed
		once per person per case.
	*/
	private static function collectConflicts($sql, $params, $match, &$conflict_array, &$seen)
	{
		$result = DB::preparedQuery($sql,$params)
			or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		
		while ($tmp_row = DBResult::fetchRow($result))
		{
			$key = $match . ':' . (string) $tmp_row['contact_id'] . ':'
				. (string) $tmp_row['case_id'];
			
			if (isset($seen[$key]))
			{
				continue;
			}
			
			$seen[$key] = true;
			$tmp_row['match'] = $match;
			$conflict_array[] = $tmp_row;
		}
	}
	
	
	/*
	Creates a duplicate of an existing case record with a new case_id.  
	Copies primary client, eligibility information.
	Sets the new case's status to New/Hold, assigns a new case number, ignores other case data.
	Ignores case notes.  Ignores non-primary client case contacts.
	*/
	public function duplicate()
	{
		$autonumber_on_new_case = pl_settings_get('autonumber_on_new_case');
		$dup = new pikaCase();
		
		// Only copy certain data from 'cases' table.
		$dup->setValue('client_id', $this->getValue('client_id'));
		$dup->setValue('children', $this->getValue('children'));
		$dup->setValue('adults', $this->getValue('adults'));
		$dup->setValue('persons_helped', $this->getValue('persons_helped'));
		
		$dup->setValue('income_type0', $this->getValue('income_type0'));
		$dup->setValue('annual0', $this->getValue('annual0'));
		$dup->setValue('income_type1', $this->getValue('income_type1'));
		$dup->setValue('annual1', $this->getValue('annual1'));
		$dup->setValue('income_type2', $this->getValue('income_type2'));
		$dup->setValue('annual2', $this->getValue('annual2'));
		$dup->setValue('income_type3', $this->getValue('income_type3'));
		$dup->setValue('annual3', $this->getValue('annual3'));
		$dup->setValue('income_type4', $this->getValue('income_type4'));
		$dup->setValue('annual4', $this->getValue('annual4'));
		$dup->setValue('income', $this->getValue('income'));
		$dup->setValue('poverty', $this->getValue('poverty'));
		
		$dup->setValue('asset_type0', $this->getValue('asset_type0'));
		$dup->setValue('asset0', $this->getValue('asset0'));
		$dup->setValue('asset_type1', $this->getValue('asset_type1'));
		$dup->setValue('asset1', $this->getValue('asset1'));
		$dup->setValue('asset_type2', $this->getValue('asset_type2'));
		$dup->setValue('asset2', $this->getValue('asset2'));
		$dup->setValue('asset_type3', $this->getValue('asset_type3'));
		$dup->setValue('asset3', $this->getValue('asset3'));
		$dup->setValue('asset_type4', $this->getValue('asset_type4'));
		$dup->setValue('asset4', $this->getValue('asset4'));
		$dup->setValue('assets', $this->getValue('assets'));
		
		$dup->setValue('citizen', $this->getValue('citizen'));
		$dup->setValue('referred_by', $this->getValue('referred_by'));
		$dup->setValue('case_county', $this->getValue('case_county'));
		$dup->setValue('case_zip', $this->getValue('case_zip'));
		
		if ($this->valueExists('kids_ages')) 
		{
			$dup->setValue('kids_ages', $this->getValue('kids_ages'));
		}
		
		if ($autonumber_on_new_case)
		{
			// if this is unset, the case number won't generate properly
			$dup->setValue('office', $this->getValue('office'));
		}
		
		// now take care of setting up the new conflict record for the primary client
		$dup->addContact($this->getValue('client_id'), 1);
		$dup->save();
		return $dup;
	}
	
	
	public function removeContact($conflict_id)
	{
		$sql = "DELETE FROM conflict WHERE conflict_id='{$conflict_id}' AND case_id='{$this->case_id}' LIMIT 1";
		DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		
		if (DB::affectedRows() != 1)
		{
			trigger_error("Error: " . DB::affectedRows() . " rows deleted");
		}
		
		$this->resetConflictStatus();
		return true;
	}
	
	public function getCaseAttorneysDB()
	{
		$sql = "(SELECT users.* FROM users JOIN cases ON cases.user_id = users.user_id WHERE 1 AND case_id = '{$this->case_id}' LIMIT 1)
				UNION
				(SELECT users.* FROM users JOIN cases ON cases.cocounsel1 = users.user_id WHERE 1 AND case_id = '{$this->case_id}' LIMIT 1)
				UNION
				(SELECT users.* FROM users JOIN cases ON cases.cocounsel2 = users.user_id WHERE 1 AND case_id = '{$this->case_id}' LIMIT 1);";
		$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		return $result;
	}
	
	public function getCasePbAttorneysDB()
	{
		$sql = "(SELECT pb_attorneys.* FROM pb_attorneys JOIN cases ON cases.pba_id1 = pb_attorneys.pba_id WHERE 1 AND case_id = '{$this->case_id}' LIMIT 1)
				UNION
				(SELECT pb_attorneys.* FROM pb_attorneys JOIN cases ON cases.pba_id2 = pb_attorneys.pba_id WHERE 1 AND case_id = '{$this->case_id}' LIMIT 1)
				UNION
				(SELECT pb_attorneys.* FROM pb_attorneys JOIN cases ON cases.pba_id3 = pb_attorneys.pba_id WHERE 1 AND case_id = '{$this->case_id}' LIMIT 1);";
		$result = DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
		return $result;
	}
	
	public function deleteOutcomes()
	{
		$sql = "DELETE FROM outcomes WHERE case_id = {$this->case_id}";		
		return DB::query($sql) or trigger_error("SQL: " . $sql . " Error: " . DB::error());
	}
	
	public function addOutcome($outcome_goal_id, $result)
	{
		require_once('pikaOutcome.php');
		
		$o = new pikaOutcome();
		$o->case_id = $this->case_id;
		$o->outcome_goal_id = $outcome_goal_id;
		$o->result = $result;
		$o->save();
		return true;	
	}
}


?>
