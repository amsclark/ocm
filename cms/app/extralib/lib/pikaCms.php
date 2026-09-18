<?php
/*	The pikaCMS object encapsulates all data manipulation & retrieval logic for Pika CMS.
*/
/**
*
* pikaCms
*
* @author   Aaron Worley <amworley@pikasoftware.net>
* @version  v 3
* @access   public
*/
class pikaCms
{
	var $doc_library_path = '/library';
	
	// CASES
	
	function fetchCase($case_id, $number='')
	{
		if($number)
		{
			$sql = "SELECT * FROM cases WHERE number=? LIMIT 1";
			$params = array($number);
		}
		
		else
		{
			$sql = "SELECT * FROM cases WHERE case_id=? LIMIT 1";
			$params = array($case_id);
		}
		
		return DB::preparedQuery($sql, $params);
	}
	
	
	function newCase($a)
	{
		global $plUserId, $pikaDefIntake;
		
		is_array($a) or
		die(pl_html_error_notice('Pika is sick', 'new case variable not an array'));
		
		$a['case_id'] = pl_new_id('cases');
		$a['intake_user_id'] = $plUserId;
		
		if (!isset($a['intake_type']) || !(strlen($a['intake_type']) > 0))
		{
			$a['intake_type'] = $pikaDefIntake;
		}
		
		if (!isset($a['fingerprint']) || !(strlen($a['fingerprint']) > 0))
		{
			/*	The fingerprint identifies a case row, so it must not be
				derivable from the time the row was made. md5(uniqid(rand(),
				true)) was: both of its inputs are the clock. random_bytes()
				is not, and 16 bytes keeps the same 32-character width.
			*/
			$a['fingerprint'] = bin2hex(random_bytes(16));
		}
		
		// Open date always needs to be set, so that the client age can be calculated
		if (!array_key_exists('open_date', $a) || !$a['open_date'])
		{
			$a['open_date'] = date('Y-m-d');
		}
		
		if ($a["number"] == 'auto')
		{
			$a["number"] = $this->generateCaseNumber($a);
		}
		
		$a['created'] = date('YmdHis');
		
		$sql = pl_build_sql('INSERT', 'cases', $a);
		$result = DB::query($sql);
		
		return $a['case_id'];
	}
	
	
	function updateCase($a)
	{
		if (array_key_exists('number', $a) && $a["number"] == 'auto')
		{
			$a["number"] = $this->generateCaseNumber($a);
		}
		
		if (array_key_exists("open_date", $a))
		{
			$a["open_date"] = pl_mogrify_date($a["open_date"]);
		}
		
		if (array_key_exists("close_date", $a))
		{
			$a["close_date"] = pl_mogrify_date($a["close_date"]);
		}
				
		// Don't allow the close date to occur before the open date
		if (array_key_exists("open_date", $a) && array_key_exists("close_date", $a) 
			&& strlen($a['close_date']) > 0 && strlen($a['open_date']) > 0
			&& strtotime($a['close_date']) < strtotime($a['open_date']))
		{
			unset($a['close_date']);
		}
		
		$sql = pl_build_sql('UPDATE', 'cases', $a);
		
		$result = DB::query($sql);
		
		return 1;
	}
	
	
	/*
	Creates a duplicate of an existing case record with a new case_id.  
	Copies primary client, eligibility information.
	Sets the new case's status to New/Hold, assigns a new case number, ignores other case data.
	Ignores case notes.  Ignores non-primary client case contacts.
	*/
	function duplicateCase($case_id)
	{
		global $plSettings, $plFields;
		
		// Get copy of original case info
		$result = $this->fetchCase($case_id);
		$row = DBResult::fetchRow($result);

		// Only copy certain data from 'cases' table
		$case_info["client_id"] = $row['client_id'];
		$case_info["children"] = $row["children"];
		$case_info["adults"] = $row["adults"];
		
		$case_info["income_type0"] = $row["income_type0"];
		$case_info["annual0"] = $row["annual0"];
		$case_info["income_type1"] = $row["income_type1"];
		$case_info["annual1"] = $row["annual1"];
		$case_info["income_type2"] = $row["income_type2"];
		$case_info["annual2"] = $row["annual2"];
		$case_info["income_type3"] = $row["income_type3"];
		$case_info["annual3"] = $row["annual3"];
		$case_info["income_type4"] = $row["income_type4"];
		$case_info["annual4"] = $row["annual4"];
		
		$case_info["asset_type0"] = $row["asset_type0"];
		$case_info["asset0"] = $row["asset0"];
		$case_info["asset_type1"] = $row["asset_type1"];
		$case_info["asset1"] = $row["asset1"];
		$case_info["asset_type2"] = $row["asset_type2"];
		$case_info["asset2"] = $row["asset2"];
		$case_info["asset_type3"] = $row["asset_type3"];
		$case_info["asset3"] = $row["asset3"];
		$case_info["asset_type4"] = $row["asset_type4"];
		$case_info["asset4"] = $row["asset4"];
		
		$case_info["kids_ages"] = $row["kids_ages"];
		$case_info["citizen"] = $row["citizen"];
		$case_info["referred_by"] = $row["referred_by"];
		$case_info["county"] = $row["county"];
		$case_info["zip"] = $row["zip"];
				
		if ($plSettings['autonumber_on_new_case'])
		{
			// if this is unset, the case number won't generate properly
			$case_info["office"] = $row["office"];
			
			$case_info["number"] = 'auto';
		}		
		
		// create duplicated case, save its case_id
		$case_id = $this->newCase($case_info);
		
		// now take care of setting up the new conflict record for the primary client
		$this->addCaseContact($case_id, $case_info['client_id'], CLIENT);
		
		return $case_id;
	}
	
	
	/*
	When MySQL officially supports UNION statements, it will be possible to
	delete any 'primary_name' aliases records and to drop the primary_name field.
	Investigate performance first.
	*/
	function newAlias($data)
	{
		if (!is_array($data))
		{
			return false;
		}
		
		if ($data["first_name"])
		{
			$data["mp_first"] = metaphone(_pika_first_name_only($data["first_name"]));
		}
		
		if ($data["last_name"])
		{
			$data["mp_last"] = metaphone($data["last_name"]);
		}
		
		$data['first_name'] = ucfirst($data['first_name']);
		$data['middle_name'] = ucfirst($data['middle_name']);
		$data['extra_name'] = ucfirst($data['extra_name']);
		$data['last_name'] = ucfirst($data['last_name']);
		
		$data['alias_id'] = pl_new_id('aliases');
		
		$sql = pl_build_sql('INSERT', 'aliases', $data);
		DB::query($sql);
		
		return true;
	}
	
	function updateAlias($data)
	{
		if ($data["first_name"])
		{
			$data["mp_first"] = metaphone(_pika_first_name_only($data["first_name"]));
		}
		
		if ($data["last_name"])
		{
			$data["mp_last"] = metaphone($data["last_name"]);
		}
		
		$data['first_name'] = ucfirst($data['first_name']);
		$data['middle_name'] = ucfirst($data['middle_name']);
		$data['extra_name'] = ucfirst($data['extra_name']);
		$data['last_name'] = ucfirst($data['last_name']);

		
		if (is_numeric($data['alias_id']))
		{
			$sql = pl_build_sql('UPDATE', 'aliases', $data);
			DB::query($sql);
		
			return true;
		}
		
		else if ($data['contact_id'] && true == $data['primary_name'])
		{
			$sql = 'SELECT alias_id FROM aliases WHERE contact_id= ? AND primary_name=1';
			$result = DB::preparedQuery($sql, array($data['contact_id']));
			$row = DBResult::fetchRow($result);
			
			$data['alias_id'] = $row['alias_id'];
			
			$sql = pl_build_sql('UPDATE', 'aliases', $data);
			DB::query($sql);
			
			return true;
		}
		
		else 
		{
			die(pl_html_error_notice('Pika Error', 'Alias update failed'));
		}
	}
	
	function fetchAlias($alias_id='')
	{
		if ($alias_id)
		{
			$sql = 'SELECT * FROM aliases WHERE alias_id= ? ';
			return DB::preparedQuery($sql, array($alias_id));
		}
	}
	
	function fetchAliases($contact_id)
	{
		if ($contact_id)
		{
			$sql = 'SELECT * FROM aliases WHERE contact_id= ? ';
			return DB::preparedQuery($sql, array($contact_id));
		}
	}
		
	function deleteAlias($alias_id='', $contact_id='')
	{
		if ($alias_id && !$contact_id)
		{
			DB::preparedQuery('DELETE FROM aliases WHERE alias_id= ? LIMIT 1',
				array($alias_id));
		}
		
		else if ($contact_id && !$alias_id)
		{
			DB::preparedQuery('DELETE FROM aliases WHERE contact_id= ? ',
				array($contact_id));
		}
		
		return true;
	}
			
	
	
	// TODO - split this into fetchContact() and fetchContactsByMetaphone()?
	function fetchContact($contact_id='', $last_name='', $first_name='')
	{
		if ($last_name && $first_name)
		{
			$mp_last = metaphone($last_name);
			$mp_first = metaphone(_pika_first_name_only($first_name));
			
			$sql = "SELECT contacts.* FROM aliases
					LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id
				    WHERE aliases.mp_last LIKE '$mp_last' 
				    AND aliases.mp_first LIKE '$mp_first'
				    ORDER BY last_name, first_name";
		}
		
		else if ($last_name)
		{
			$mp_last = metaphone($last_name);
			$sql = "SELECT contacts.* FROM aliases
					LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id
					WHERE aliases.mp_last LIKE '$mp_last' ORDER
		    		BY last_name, first_name";
		}
		
		/*
		since there's a specific contact we're looking for, grab the case number
		*/
		else
		{
			/*	The two branches above build their LIKE values with
				metaphone(), which returns letters only, so they carry
				nothing that could end the quoted string. This one takes the
				id from the caller, and most callers read it out of the
				request.
			*/
			$sql = "SELECT * FROM contacts WHERE contact_id='"
				. DB::escapeString($contact_id) . "'
					LIMIT 1";
		}
		
		// echo $sql;
		
		return DB::query($sql);
	}
	
	function fetchContacts($filter)
	{
		$sql = "SELECT contacts.* FROM aliases LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id WHERE 1";

		/*	Escape every value once, here, rather than at each of the clauses
			below. pikaMisc::getCases() takes the same approach with its own
			filter array, and doing it in one place means a filter added later
			cannot be the one that gets forgotten.
		*/
		if (is_array($filter))
		{
			foreach ($filter as $f_key => $f_val)
			{
				if (!is_array($f_val))
				{
					$filter[$f_key] = DB::escapeString($f_val);
				}
			}
		}
		
		if ($filter['telephone'])
		{
			/*
			$mp_last = metaphone($last_name);
			$mp_first = metaphone(_pika_first_name_only($first_name));
			*/
			
			$sql .= " AND (phone = '{$filter['telephone']}'
					OR phone_alt = '{$filter['telephone']}')";
		}
		
		if ($filter['notes'])
		{
			$sql .= " AND notes LIKE '%{$filter['notes']}%'";
		}
		
		if ($filter['state_id'])
		{
			$sql .= " AND aliases.state_id='{$filter['state_id']}'";
		}

		$sql .= " ORDER BY last_name, first_name";
		
		// echo $sql;
		
		return DB::query($sql);
	}
	
	/*
	If ZIP is present and other address fields are not, try to fill them in
	based on the ZIP provided.  If ZIP is not present, attempt to fill in ZIP and county 
	information based on City and State.
	
	The mp_first/_last fields should never be user-specified.  They are instead
	calculated and saved in this method.
	*/
	function newContact($a)
	{
		$contact_id = pl_new_id('contacts');
		
		$a["contact_id"] = $contact_id;
		
		if (isset($a["first_name"]))
		{
			$a["mp_first"] = metaphone(_pika_first_name_only($a["first_name"]));
		}
		
		if (isset($a["last_name"]))
		{
			$a["mp_last"] = metaphone($a["last_name"]);
		}

		if ($a["zip"] && (!$a["city"] || !$a["state"] || !$a["county"]))
		{
			$sql = "SELECT * FROM zip_codes WHERE zip=?";
			$result = DB::preparedQuery($sql, array($a['zip']));
			
			if (DBResult::numRows($result) >= 1)
			{
				$r = DBResult::fetchRow($result);
				
				if (!$a["city"])
				$a["city"] = $r["city"];
				
				if (!$a["state"])
				$a["state"] = $r["state"];
				
				if (!$a["county"])
				$a["county"] = $r["county"];
			}
		}
		
		else if (!$a['zip'])
		{
			$sql = "SELECT * FROM zip_codes WHERE city=? AND state=?";
			$result = DB::preparedQuery($sql, array($a['city'], $a['state']));
			
			// if there's more than one zip code in that city, don't auto-fill
			if (DBResult::numRows($result) == 1)
			{
				$r = DBResult::fetchRow($result);
				
				$a["zip"] = $r["zip"];
				
				if (!$a["county"])
				$a["county"] = $r["county"];
			}
		}
		
		// Automatically make the first letter of these fields uppercase
		$a['first_name'] = ucfirst($a['first_name']);
		$a['middle_name'] = ucfirst($a['middle_name']);
		$a['extra_name'] = ucfirst($a['extra_name']);
		$a['last_name'] = ucfirst($a['last_name']);
		$a['city'] = ucfirst($a['city']);
		$a['county'] = ucfirst($a['county']);
		// States are always uppercase
		$a['state'] = strtoupper($a['state']);
		
		$sql = pl_build_sql('INSERT', 'contacts', $a);
		DB::query($sql);
		
		// create the corresponding alias record for this contact record
		$a['primary_name'] = '1'; // true;
		$this->newAlias($a);
		
		return $contact_id;
	}
	
	
	/*
	If ZIP is present and other address fields are not, try to fill them in
	based on the ZIP provided.  If ZIP is not present, attempt to fill in ZIP and county 
	information based on City and State.
	
	The mp_first/_last fields should never be user-specified.  They are instead
	calculated and saved in this method.
	*/
	function updateContact($a)
	{
		/*
		else 
		{
			$a['mp_first'] = '';
		}
		*/
		
		/*
		else 
		{
			$a['mp_last'] = '';
		}
		*/
		
		// Do not allow a user to delete the entire contact name; last_name is the bare minimum
		if ('' == $a['last_name'])
		{
			return 0;
		}
		
		
		if ($a["zip"] && (!$a["city"] || !$a["state"] || !$a["county"]))
		{
			// Weed out 9 digit ZIP codes
			$five_digit_zip = substr($a['zip'], 0, 5);
			
			$sql = "SELECT * FROM zip_codes WHERE zip=?";
			$result = DB::preparedQuery($sql, array($five_digit_zip));
			
			if (DBResult::numRows($result) >= 1)
			{
				$r = DBResult::fetchRow($result);
				
				if (!$a["city"])
				$a["city"] = $r["city"];
				
				if (!$a["state"])
				$a["state"] = $r["state"];
				
				if (!$a["county"])
				$a["county"] = $r["county"];
			}
		}
		
		else if (!$a['zip'])
		{
			$sql = "SELECT * FROM zip_codes WHERE city=? AND state=?";
			$result = DB::preparedQuery($sql, array($a['city'], $a['state']));
			
			// if there's more than one zip code in that city, don't auto-fill
			if (DBResult::numRows($result) == 1)
			{
				$r = DBResult::fetchRow($result);
				
				$a["zip"] = $r["zip"];
				
				if (!$a["county"])
				$a["county"] = $r["county"];
			}
		}
		
		if ($a["first_name"])
		{
			$a["mp_first"] = metaphone(_pika_first_name_only($a["first_name"]));
		}
		
		if ($a["last_name"])
		{
			$a["mp_last"] = metaphone($a["last_name"]);
		}
		
		$a['first_name'] = ucfirst($a['first_name']);
		$a['middle_name'] = ucfirst($a['middle_name']);
		$a['extra_name'] = ucfirst($a['extra_name']);
		$a['last_name'] = ucfirst($a['last_name']);
		$a['city'] = ucfirst($a['city']);
		$a['county'] = ucfirst($a['county']);
		
		$a['state'] = strtoupper($a['state']);
		
		
		$sql = pl_build_sql('UPDATE', 'contacts', $a);
		
		$result = DB::query($sql);
		
		// handle this contact's primary alias
		$a['primary_name'] = true;
		$this->updateAlias($a);
		
		return 1;
	}
	
	
	/* 
	Return index # of first record with a last name that matches $str, or is greater
	(alphabetically) than $str.
	*/
	function fetchContactOffset($str)
	{
		// this should all be handled case-insensitively :)
		$str = strtolower($str);
		
		$letter = DB::escapeString(substr($str, 0, 1));
		
		$vals = explode(",", $str);
		$vals[0] = ltrim($vals[0]);
		
		if (sizeof($vals) > 1)
		{
			$vals[1] = ltrim($vals[1]);
			
			/*	$str is the letter box on the contact list, which reaches
				here through pl_grab_var(). That filter encodes < and >
				and nothing else, so a quote arrives intact.
			*/
			$v0 = DB::escapeString($vals[0]);
			$v1 = DB::escapeString($vals[1]);

			$sql = "SELECT COUNT(*) AS 'position' FROM aliases WHERE last_name LIKE '$letter%' AND
((last_name < '{$v0}') OR (last_name <= '{$v0}' AND first_name < '{$v1}'))";
		}
		
		else
		{
			$sql = "SELECT COUNT(*) AS 'position' FROM aliases WHERE last_name LIKE '$letter%' AND last_name < '"
				. DB::escapeString($vals[0]) . "'";
		}

		$result = DB::query($sql);
		$row = DBResult::fetchRow($result);
			
		return $row['position'];
	}
	
	/*
	function fetchContactOffsetOldSlow($str)
	{
		// this should all be handled case-insensitively :)
		$str = strtolower($str);
		
		$letter = DB::escapeString(substr($str, 0, 1));
		
		$vals = explode(",", $str);
		
		if (sizeof($vals) > 1)
		{
			$vals[1] = ltrim($vals[1]);
			
			$sql = "SELECT last_name, first_name FROM aliases 
				WHERE last_name LIKE '$letter%' ORDER BY last_name, first_name";

			// echo $sql;

			$result = pl_query($sql);
			
			$z = 0;
			
			while ($row = $result->fetchRow())
			{
				if ($vals[0] <= strtolower($row['last_name'])
					&& $vals[1] <= strtolower($row['first_name']))
				{
					return $z;
				}
				
				elseif ($vals[0] < strtolower($row['last_name']))
				{
					return $z;
				}
				
				$z++;
			}
		}
		
		else
		{
			$sql = "SELECT last_name FROM aliases WHERE last_name LIKE '$letter%' ORDER BY last_name";
			//echo $sql;
			
			$result = pl_query($sql);
			
			$z = 0;
			
			while ($row = $result->fetchRow())
			{
				if ($str <= strtolower($row['last_name']))
				{
					return $z;
				}
				
				$z++;
			}
		}
		
		return $z;
	}
	*/	
	
	// get all contact records, in alphabetical order (within a range)
	function fetchLetterContacts($letter, &$dataset_size, $offset='0', $limit='5')
	{
		$letter = DB::escapeString($letter);
		$offset = (int) $offset;
		$limit = (int) $limit;
		
		// get the total number of contacts
		$result = DB::query("SELECT COUNT(*) AS count FROM aliases WHERE last_name LIKE '$letter%'");
		$row = DBResult::fetchRow($result);
		$dataset_size = $row["count"];
		
		$sql = "SELECT contacts.*, aliases.last_name AS last_name, aliases.first_name AS first_name, aliases.extra_name AS extra_name, aliases.middle_name AS middle_name
			    FROM aliases LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id 
				WHERE aliases.last_name LIKE '$letter%'
			    ORDER BY aliases.last_name, aliases.first_name, aliases.extra_name, aliases.middle_name
			    LIMIT $offset, $limit";
		
		//echo $sql;
		
		return DB::query($sql);
	}
	
	
	
	
	// CASE-RELATED METHODS
	
	/*
	Fetch information about all cases a contact is involved in
	*/
	function fetchContactCases($contact_id)
	{
		$sql = "SELECT cases.*, conflict.relation_code, menu_relation_codes.label AS role
				FROM conflict LEFT JOIN cases ON conflict.case_id=cases.case_id
				LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
				WHERE conflict.contact_id=" . (int) $contact_id . " ORDER BY conflict.relation_code ASC";
		return DB::query($sql);
	}
	
	
	// get all contact records related to a case
	function fetchCaseContacts($case_id, $r_type='')
	{
		/*	Both values go into the statement unquoted, so neither needed a
			quote character to be read as SQL rather than as data. The
			shortest path in is dataops.php's contact list, which grabs
			case_id out of the query string with no filter mode at all.

			conflict.case_id is int(11) and conflict.relation_code is
			tinyint(4), so cast: a value that is not a number matches no
			row, which is the right answer for a lookup by id.
		*/
		$case_id = (int) $case_id;
		$r_type = (int) $r_type;

		// sort these by order they were added to the case
		
		$sql = "SELECT conflict.conflict_id, conflict.relation_code, contacts.*, menu_relation_codes.label
			    FROM conflict
			    LEFT JOIN contacts
			    ON conflict.contact_id=contacts.contact_id 
				LEFT JOIN menu_relation_codes
				ON conflict.relation_code=menu_relation_codes.value
				WHERE conflict.case_id=$case_id";
		
		if ($r_type)
		{
			$sql .= " AND conflict.relation_code=$r_type";
		}
		
		$sql .= " ORDER BY relation_code ASC, conflict_id ASC";
		// echo $sql;
		
		return DB::query($sql);
	}
	
	// add a contact to a case
	function addCaseContact($case_id, $contact_id, $relation_code)
	{
		// this prevents duplicate conflict records
		// it slows things down, though
		/*
		$sql = "SELECT conflict_id FROM conflict
				WHERE contact_id=$contact_id
				AND case_id=$case_id
				AND relation_code=$relation_code";
		$res = pl_query($sql);
		if ($res->numRows() != 0)
		{
			return FALSE;
		}
		*/
		/*	The INSERT below lists these unquoted, for the same reason as
			fetchCaseContacts() above: all four are integer columns.
		*/
		$case_id = (int) $case_id;
		$contact_id = (int) $contact_id;
		$relation_code = (int) $relation_code;

		$extra_sql = '';
		$conflict_id = (int) pl_new_id('conflict');
		
		$sql = "INSERT INTO conflict
			    (conflict_id, contact_id, case_id, relation_code) VALUES
			    ($conflict_id, $contact_id, $case_id, $relation_code)";
		$result = DB::query($sql);
		
		
		// Make certain that the case's potential conflict field is up-to-date
		/*
		$poten_conflicts = $this->conflictCheck($case_id);

		if (sizeof($poten_conflicts) > 0)
		{
			pl_query("UPDATE cases SET poten_conflicts = 1, conflicts = NULL WHERE case_id=$case_id LIMIT 1");
		}
		
		else 
		{
			pl_query("UPDATE cases SET poten_conflicts = 0, conflicts = NULL WHERE case_id=$case_id LIMIT 1");
		}
		*/
		$this->resetConflictStatus($case_id);
		
		// If this is the first client for this case, make them the primary client and set age, county, ZIP code fields
		if (1 == $relation_code)
		{
			$result = DB::query("SELECT birth_date, open_date, county, zip 
								FROM conflict 
								LEFT JOIN cases ON conflict.case_id=cases.case_id
								LEFT JOIN contacts ON conflict.contact_id=contacts.contact_id 
								WHERE conflict.case_id=$case_id AND relation_code=1");
			
			if (DBResult::numRows($result) == 1)
			{
				$row = DBResult::fetchRow($result);
				
				if ($row['birth_date'] && $row['open_date'])
				{
					$client_age = pl_calc_age($row['birth_date'], $row['open_date']);
					$extra_sql .= ", client_age=" . (int) $client_age;
				}
				
				if ($row['zip'])
				{
					$extra_sql .= ", case_zip='" . DB::escapeString($row['zip']) . "'";
				}
				
				if ($row['county'])
				{
					$extra_sql .= ", case_county='" . DB::escapeString($row['county']) . "'";
				}
				
				DB::query("UPDATE cases SET client_id={$contact_id}{$extra_sql} WHERE case_id='$case_id' LIMIT 1");
			}
		}
		
		// TODO: optimize by merging the 2 cases UPDATEs
		
		return TRUE;
	}
	
	
	// removes a contact from a case
	function deleteConflict($conflict_id, $case_id)
	{
		$sql = "DELETE FROM conflict WHERE conflict_id=" . (int) $conflict_id . " LIMIT 1";
		$result = DB::query($sql);
		
		/*
		$poten_conflicts = $this->conflictCheck($case_id);
		if (sizeof($poten_conflicts) > 0)
		{
			pl_query("UPDATE cases SET poten_conflicts = 1, conflicts = NULL WHERE case_id=$case_id LIMIT 1");
		}
		
		else 
		{
			pl_query("UPDATE cases SET poten_conflicts = 0, conflicts = NULL WHERE case_id=$case_id LIMIT 1");
		}
		*/
		
		$this->resetConflictStatus($case_id);
		
		return $result;
	}

	
	/*	Look for other contacts matching a name, using metaphone.
		
		This is a second copy of pikaContact::metaphoneContactCheck(). That copy
		was fixed to bind its parameters; this one was missed, and kept building
		the statement by interpolation:
		
		  - on the short-metaphone branch below, $mp_last and $mp_first are the
		    caller's raw $last_name and $first_name, and they went straight into
		    LIKE '$mp_last'. metaphone('A') is one character, so a last name of
		    "A" with any first name at all took that branch;
		  - $ssn went into ssn='$ssn' on every branch.
		
		A contact record is typed in by whoever takes the intake, so that was a
		way to run a statement of your choosing against the case database from
		the address book.
		
		Nothing in this tree calls this copy -- the one caller,
		cms/merge_contacts.php, holds a pikaContact -- so it was not reachable.
		It is hardened rather than deleted because pikaCms is a public class and
		somebody's fork may well call it.
		
		The two column names are still written into the statement, because a
		bound parameter cannot name a column. They are chosen by the branch below
		and are never anything the caller supplied; the check says so out loud so
		that a later edit which starts passing a column name in has to notice.
	*/
	function metaphoneContactCheck($last_name="", $first_name='', $ssn='')
	{
		$mp_last = metaphone($last_name);
		$mp_first = metaphone(_pika_first_name_only($first_name));
		
		if (strlen($mp_last) > 1)
		{
			// metaphone fields are only 8 chars in size
			$mp_first = substr($mp_first, 0, 8);
			$mp_last = substr($mp_last, 0, 8);
			
			$match_first = 'mp_first';
			$match_last = 'mp_last';
		}
		
		else
		{
			// just use the entire name if $mp_last is extremely small
			$mp_last = $last_name;
			$mp_first = $first_name;
			
			$match_first = 'first_name';
			$match_last = 'last_name';
		}
		
		$valid_columns = array('mp_first', 'mp_last', 'first_name', 'last_name');
		
		if (!in_array($match_first, $valid_columns, true)
			|| !in_array($match_last, $valid_columns, true))
		{
			trigger_error('Invalid column name in metaphoneContactCheck',
				E_USER_WARNING);
			return false;
		}
		
		$params = array();
		$ssn_sql = '';
		$has_ssn = ('' !== (string) $ssn);
		
		$order = ' ORDER BY aliases.last_name, aliases.first_name,'
			. ' aliases.extra_name, aliases.middle_name';
		
		/*
		Organizations will only have a $last_name, which makes them a
		special case.
		*/
		
		// If $mp_last has a trailing wild card, it will generate too many false hits
		if (!$mp_first && $mp_last)
		{
			$params[] = $mp_last;
			
			if ($has_ssn)
			{
				$ssn_sql = 'OR aliases.ssn = ? ';
				$params[] = $ssn;
			}
			
			$sql = "SELECT contacts.*
				    FROM aliases LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id
				    WHERE (aliases.{$match_last} LIKE ? {$ssn_sql})" . $order;
		}
		
		else if ($mp_last)
		{
			$params[] = $mp_last;
			$params[] = $mp_first;
			
			if ($has_ssn)
			{
				$ssn_sql = 'OR aliases.ssn = ? ';
				$params[] = $ssn;
			}
			
			$sql = "SELECT contacts.*
				    FROM aliases LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id
				    WHERE (aliases.{$match_last} LIKE ?
				    AND aliases.{$match_first} LIKE ? {$ssn_sql})" . $order;
		}
		
		else
		{
			$params[] = $ssn;
			
			$sql = "SELECT contacts.*, aliases.ssn AS ssn
				    FROM aliases LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id
				    WHERE aliases.ssn = ?" . $order;
		}
		
		return DB::preparedQuery($sql, $params);
	}
	
	/*
	Return an array of contact_id's for individuals who may pose a risk of conflict
	of interest for a given case
	*/
	function conflictCheck($case_id)
	{
		$case_id = DB::escapeString($case_id);
		$conflict_array = array();
		
		$result = DB::query("SELECT contact_id, relation_code FROM conflict WHERE case_id='$case_id'");
		
		/*	Read the parties out before counting. The count below runs on the
			same connection, and starting it while this result is still open
			loses this result.
		*/
		$parties = array();
		
		while ($row = DBResult::fetchRow($result))
		{
			$parties[] = $row;
		}
		
		foreach ($parties as $row)
		{
			/*	"relation_code != this party's role" counted anybody who was
				not in the same seat, so a judge on two cases raised the flag
				on both of them and a client here matching a household member
				there raised it as well. Count only the roles that genuinely
				oppose this one; see pl_conflict_opposing_roles().
			*/
			$opposing_roles = pl_conflict_opposing_roles($row['relation_code']);
			
			if (empty($opposing_roles))
			{
				continue;
			}
			
			$role_placeholders = implode(',',array_fill(0,count($opposing_roles),'?'));
			
			$result_b = DB::preparedQuery("SELECT COUNT(*) AS tally FROM conflict
				WHERE contact_id = ? AND relation_code IN ({$role_placeholders})",
				array_merge(array($row['contact_id']),$opposing_roles));
			$row_b = DBResult::fetchRow($result_b);
			
			if ($row_b['tally'] > 0)
			{
				$conflict_array[] = $row['contact_id'];
			}
		}
		
		return $conflict_array;
	}

	function resetConflictStatus($case_id, $reset_verification = true)
	{
		$case_id = DB::escapeString($case_id);
		$tally = 0;
		$result = DB::query("SELECT contact_id, relation_code FROM conflict WHERE case_id='$case_id'");
		$conflict_reset_sql = '';
		
		if ($reset_verification)
		{
			$conflict_reset_sql = ', conflicts = NULL';
		}
		
		/*	Read the parties out before counting, for the same reason as
			conflictCheck() above.
		*/
		$parties = array();
		
		while ($row = DBResult::fetchRow($result))
		{
			$parties[] = $row;
		}
		
		foreach ($parties as $row)
		{
			// Same role gate as conflictCheck(); see pl_conflict_opposing_roles().
			$opposing_roles = pl_conflict_opposing_roles($row['relation_code']);
			
			if (empty($opposing_roles))
			{
				continue;
			}
			
			$role_placeholders = implode(',',array_fill(0,count($opposing_roles),'?'));
			
			$result_b = DB::preparedQuery("SELECT COUNT(*) AS tally FROM conflict
				WHERE contact_id = ? AND relation_code IN ({$role_placeholders})",
				array_merge(array($row['contact_id']),$opposing_roles));
			$row_b = DBResult::fetchRow($result_b);
			
			$tally += $row_b['tally'];
		}
		
		if ($tally > 0)
		{
			DB::query("UPDATE cases SET poten_conflicts = 1{$conflict_reset_sql} WHERE case_id='$case_id' LIMIT 1");
		}
		
		else
		{
			DB::query("UPDATE cases SET poten_conflicts = 0{$conflict_reset_sql} WHERE case_id='$case_id' LIMIT 1");
		}
			
		/*	Return what was just written, the way pikaCase::resetConflictStatus()
			does. This read $row_b['tally'] - the tally of the last party looked
			at, and an undefined variable on a case with no parties at all - not
			the total the two branches above act on.
		*/
		return ($tally > 0) ? 1 : 0;
	}
	
	
	/*	Conflict of interest check for a case.
		
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
		
		cms/app/lib/pikaCase.php carries a second copy of this check, the one
		cms/modules/case-conflict.php uses. The two files cannot share one
		implementation because pika_cms.php does not put app/lib on the include
		path, so a fix here needs the same fix there.
	*/
	function fuzzyConflictCheck($case_id, $lim = 10)
	{
		$case_id = (int) $case_id;
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
			/*	"relation_code != ?" reads as "anybody but somebody in my
				own seat", which is not what a conflict is. A judge sitting
				on two cases was reported against both parties, so was a
				referral agency that had sent in more than one person, and
				so was a client here matching a household member there --
				two people on the same side of two different matters.
				
				pl_conflict_opposing_roles() returns the roles on another
				case that genuinely oppose this party's role here. A role
				in neither bucket opposes nothing, so skip the party rather
				than search on an empty list.
			*/
			$opposing_roles = pl_conflict_opposing_roles($relation_code);
			
			if (empty($opposing_roles))
			{
				continue;
			}
			
			$role_placeholders = implode(',',array_fill(0,count($opposing_roles),'?'));
			

			
			// Match by contact ID
			$sql = "SELECT conflict.*, contacts.*, number, cases.case_id, problem, status, label AS role
					FROM conflict
					LEFT JOIN contacts ON conflict.contact_id=contacts.contact_id
					LEFT JOIN cases ON conflict.case_id=cases.case_id
					LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
					WHERE relation_code IN ({$role_placeholders})
					AND conflict.contact_id = ?
					LIMIT {$lim}";
			self::collectConflicts($sql,array_merge($opposing_roles,array($contact_id)),'ID',
				$conflict_array,$seen);
			
			// Match by metaphone name and birth date
			if (strlen($mp_last) > 0)
			{
				$contacts_clause = '';
				$aliases_clause = '';
				$contacts_params = array_merge($opposing_roles,array($mp_last));
				$aliases_params = array_merge($opposing_roles,array($mp_last));
				
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
						WHERE relation_code IN ({$role_placeholders}) AND contacts.mp_last = ?{$contacts_clause}
						AND conflict.contact_id != ?
						LIMIT {$lim}";
				self::collectConflicts($sql,$contacts_params,'NAME',$conflict_array,$seen);
				
				$sql = "SELECT conflict.*, contacts.*, number, cases.case_id, problem, status, label AS role
						FROM aliases
						LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id
						LEFT JOIN conflict ON aliases.contact_id=conflict.contact_id
						LEFT JOIN cases ON conflict.case_id=cases.case_id
						LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
						WHERE relation_code IN ({$role_placeholders}) AND aliases.mp_last = ?{$aliases_clause}
						AND conflict.contact_id != ?
						LIMIT {$lim}";
				self::collectConflicts($sql,$aliases_params,'NAME',$conflict_array,$seen);
			}
			
			// Match by social security number
			if (strlen(preg_replace('/\D/','',$ssn)) > 0)
			{
				$ssn_params = array_merge($opposing_roles,array($ssn,$contact_id,$mp_last));
				
				$sql = "SELECT conflict.*, contacts.*, number, cases.case_id, problem, status, label AS role
						FROM contacts
						LEFT JOIN conflict ON contacts.contact_id=conflict.contact_id
						LEFT JOIN cases ON conflict.case_id=cases.case_id
						LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
						WHERE relation_code IN ({$role_placeholders}) AND contacts.ssn = ?
						AND conflict.contact_id != ? AND contacts.mp_last != ?
						LIMIT {$lim}";
				self::collectConflicts($sql,$ssn_params,'SSN',$conflict_array,$seen);
				
				$sql = "SELECT conflict.*, contacts.*, number, cases.case_id, problem, status, label AS role
						FROM aliases
						LEFT JOIN contacts ON aliases.contact_id=contacts.contact_id
						LEFT JOIN conflict ON aliases.contact_id=conflict.contact_id
						LEFT JOIN cases ON conflict.case_id=cases.case_id
						LEFT JOIN menu_relation_codes ON conflict.relation_code=menu_relation_codes.value
						WHERE relation_code IN ({$role_placeholders}) AND aliases.ssn = ?
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

	
		// look for potential conflicts of interest
	function fetchConflicts($contact_ids)
	{
		if (!is_array($contact_ids))
		{
			die(pl_html_error_notice('Pika is sick', 'No array provided to fetchConflicts()'));
		}
		
		$sql = "SELECT conflict.*, cases.number, cases.problem, cases.status
			    FROM conflict 
				LEFT JOIN cases 
				ON conflict.case_id=cases.case_id WHERE (";
		
		$i = 0;
		/*	each() was removed in PHP 8, so this loop was a fatal error on
			any current build. Ciprocity 9 replaced it with foreach for the
			same reason.
			
			The ids were also interpolated unquoted. contacts.contact_id is
			int(11); cast, as fetchCaseContacts() does.
		*/
		foreach ($contact_ids as $key => $val)
		{
			if (0 == $i)
			{
				$sql .= " contact_id=" . (int) $val;
			}
			
			else
			{
				$sql .= " OR contact_id=" . (int) $val;
			}
			
			$i++;
		}
		
		$sql .= ') ORDER BY contact_id';
		
		// echo $sql;
		
		return DB::query($sql);
	}
	
	/*
	function metaphoneConflictCheck($case_id)
	{
		$conflict_array = array();
		
		$sql = "SELECT * FROM conflict LEFT JOIN contacts ON conflict.contact_id=contacts.contact_id
				WHERE relation_code != $rel_code AND ssn='$ssn'";
		$sql = "SELECT * FROM conflict LEFT JOIN contacts ON conflict.contact_id=contacts.contact_id
				WHERE relation_code != $rel_code AND mp_last='' AND mp_first=''";
		
		$result = pl_query("SELECT contact_id, relation_code FROM conflict WHERE case_id=$case_id");
		
		while ($row = $result->fetchRow())
		{
			$result_b = pl_query("SELECT COUNT(*) AS tally FROM conflict
				WHERE contact_id = {$row['contact_id']} AND relation_code != {$row['relation_code']}");
			$row_b = $result_b->fetchRow();
			
			if ($row_b['tally'] > 0)
			{
				$conflict_array[] = $row['contact_id'];
			}
		}
		
		return $conflict_array;
	}
	*/
	
	function fetchNotes($case_id, $order='ASC')
	{
			$order = pl_safe_sort_direction($order);
			$case_id = DB::escapeString($case_id);
			
			$sql = "SELECT activities.*,
								users.first_name, 
								users.last_name
					FROM activities
					LEFT JOIN users ON activities.user_id=users.user_id
					WHERE case_id='$case_id'
					ORDER BY act_date $order, act_time $order, last_changed $order";

		// echo $sql;
		
		return DB::query($sql);
	}
	
	/*
	Invoke the case autonumber module, which will generate a new case number
	*/
	function generateCaseNumber($a)
	{
		// Handle custom templates.
		if (file_exists(pl_custom_directory() . "/modules/autonumber.php")) {
			require_once(pl_custom_directory() . '/modules/autonumber.php');
		} else {
			require_once('modules/autonumber.php');	
		}
		
		return autonumber($a);
	}
	
	function fetchOpenCaseList($user_id)
	{
		global $plFields;

		$user_id = DB::escapeString($user_id);
		
		// Hack to get the Iowa matching funding field to work
		$mf = '';
		if (isset($plFields['cases']['matching_funding']))
		{
			$mf = ', matching_funding';
		}
		
		$sql = "(SELECT case_id, number, problem, status, cases.user_id, cocounsel1, 
			cocounsel2, office, open_date, close_date, funding, contacts.first_name, 
			contacts.middle_name, contacts.last_name, contacts.extra_name, 
			area_code, phone{$mf} FROM cases LEFT JOIN contacts ON 
			cases.client_id=contacts.contact_id
			WHERE close_date IS NULL AND status IN (1, 2) AND 
			user_id = '{$user_id}')
			UNION
			(SELECT case_id, number, problem, status, cases.user_id, cocounsel1, 
			cocounsel2, office, open_date, close_date, funding, contacts.first_name, 
			contacts.middle_name, contacts.last_name, contacts.extra_name, 
			area_code, phone{$mf} FROM cases LEFT JOIN contacts ON 
			cases.client_id=contacts.contact_id
			WHERE close_date IS NULL AND status IN (1, 2) AND 
			cocounsel1 = '{$user_id}')
			UNION
			(SELECT case_id, number, problem, status, cases.user_id, cocounsel1, 
			cocounsel2, office, open_date, close_date, funding, contacts.first_name, 
			contacts.middle_name, contacts.last_name, contacts.extra_name, 
			area_code, phone{$mf} FROM cases LEFT JOIN contacts ON 
			cases.client_id=contacts.contact_id
			WHERE close_date IS NULL AND status IN (1, 2) AND 
			cocounsel2 = '{$user_id}')
			ORDER BY last_name, first_name ASC";
		
		return DB::query($sql);
	}
	
	function fetchCaseList($filter, &$row_count, $order_field='',
	$order='ASC', $first_row='0', $list_length='100')
	{
		global $pikaOldMysqlMode, $plSettings;
		
		/*	Every filter below reaches the statement by interpolation, and
			none of the values were escaped. Two were passed through
			pl_double_quotes(), which doubles a quote but leaves a backslash
			alone, so a trailing backslash still escaped the closing quote;
			the rest went in as they arrived.
			
			All four callers today pass a value that came back out of the
			database or that had already been checked as a number, so there
			is no live hole, but nothing in the function said so and the next
			caller had no way to know. Escape once, here, so each filter
			below is data whatever the caller hands in.
		*/
		foreach ($filter as $filter_key => $filter_value)
		{
			if (is_scalar($filter_value))
			{
				$filter[$filter_key] = DB::escapeString((string) $filter_value);
			}
		}
		
		/*	
		this little hack will save a few fractions of a second on case
		lists w/o filters.  Instead of doing a "COUNT(*)" to determine
		the number of records in the resulting list, it uses "SHOW STATUS
		TABLES" to get the number of records in the 'cases' table.  This
		is of course MySQL-specific.
		*/
		$no_filters = true;
		
		$sql = ' FROM cases 
			LEFT JOIN contacts ON cases.client_id=contacts.contact_id
			LEFT JOIN users ON cases.user_id=users.user_id
			WHERE 1 ';
		
		if (isset($filter["case_id"]) && $filter["case_id"])
		{
			/*	Unquoted, so this one filter took its value as SQL rather
				than as data and needed no quote at all to break out of.
				cases.case_id is int(11); cast for the same reason as
				fetchActivity() above.
			*/
			$sql .= " AND cases.case_id=" . (int) $filter['case_id'];
			$no_filters = false;
		}
		
		if (isset($filter["last_name"]) && $filter["last_name"])
		{
			$sql .= " AND contacts.last_name LIKE '{$filter['last_name']}%'";
			$no_filters = false;
		}
		
		
		if (isset($filter["first_name"]) && $filter["first_name"])
		{
			$sql .= " AND contacts.first_name LIKE '{$filter['first_name']}%'";
			$no_filters = false;
		}
		
		
		if (isset($filter["user_id"]) && $filter["user_id"])
		{
			$sql .= " AND (cases.user_id='{$filter["user_id"]}' OR cases.cocounsel1='{$filter["user_id"]}' OR cases.cocounsel2='{$filter["user_id"]}')";
			$no_filters = false;
		}
		
		
		if (isset($filter["pba_id"]) && $filter["pba_id"])
		{
			$sql .= " AND (cases.pba_id1='{$filter["pba_id"]}' OR cases.pba_id2='{$filter["pba_id"]}' OR cases.pba_id3='{$filter["pba_id"]}')";
			$no_filters = false;
		}

		
		if (isset($filter["client_id"]) && $filter["client_id"])
		{
			$sql .= " AND cases.client_id='{$filter["client_id"]}'";
			$no_filters = false;
		}
		
		
		if (isset($filter["office"]) && $filter["office"])
		{
			$sql .= " AND office='{$filter["office"]}'";
			$no_filters = false;
		}
		
		
		if (isset($filter["status"]) && is_numeric($filter["status"]))
		{
			$sql .= " AND status={$filter["status"]}";
			$no_filters = false;
		}
		
		
		if (isset($filter["opened_before"]) && $filter["opened_before"])
		{
			$sql .= " AND open_date < '{$filter["opened_before"]}'";
			$no_filters = false;
		}
		
		
		if (isset($filter["closed_before"]) && $filter["closed_before"])
		{
			$sql .= " AND close_date < '{$filter["closed_before"]}'";
			$no_filters = false;
		}
		
		
		if (isset($filter["opened_on_after"]) && $filter["opened_on_after"])
		{
			$sql .= " AND open_date >= '{$filter["opened_on_after"]}'";
			$no_filters = false;
		}
		
		
		if (isset($filter["closed_on_after"]) && $filter["closed_on_after"])
		{
			if ('NULL' == $filter["closed_on_after"])
			{
				$sql .= " AND close_date IS NULL";
			}
			
			else if ('NOT NULL' == $filter["closed_on_after"])
			{
				$sql .= " AND close_date IS NOT NULL";
			}
			
			else
			{
				$sql .= " AND close_date >= '{$filter["closed_on_after"]}'";
			}
			
			$no_filters = false;
		}
		
		if (isset($filter["funding"]) && $filter["funding"])
		{
			$sql .= " AND funding='{$filter["funding"]}'";
			
			$no_filters = false;
		}
		
		if ($no_filters == false)
		{
			$result = DB::query('SELECT COUNT(case_id) AS count' . $sql);
			$r = DBResult::fetchRow($result);
			$row_count = $r["count"];
		}
		
		else
		{
			$result = DB::query("SHOW TABLE STATUS FROM {$plSettings['db_name']} LIKE 'cases'");
			$r = DBResult::fetchRow($result);
			$row_count = $r["Rows"];
		}
		
		/*	next, re-run the query, this time sorting the results and only
		retrieving those records that will be displayed on this screen.
		*/
		if ($order_field && $order)
		{
			if ('last_name' == $order_field)
			{
				$order_field = 'contacts.last_name';
			}
			
			$sql .= pl_safe_order_by($order_field, $order, 'case list sort column');
		}
		
		$sql .= " LIMIT " . (int) $first_row . ", " . (int) $list_length;
		
		$full_sql = 'SELECT case_id, number, problem, status, cases.user_id, cocounsel1, 
			cocounsel2, office, open_date, close_date, funding, client_id, 
			contacts.first_name as \'contacts.first_name\', contacts.middle_name AS \'contacts.middle_name\',
			contacts.last_name AS \'contacts.last_name\', contacts.extra_name AS \'contacts.extra_name\', 
			area_code, phone, users.first_name as \'users.first_name\', 
			users.middle_name as \'users.middle_name\',	users.last_name as \'users.last_name\',
			users.extra_name as \'users.extra_name\' ' . $sql;
		
		// echo "$full_sql";
		
		return DB::query($full_sql);
	}
	
	
	
	// STAFF
	
	function fetchStaff($user_id='')
	{
		if ($user_id)
		$sql = "SELECT * FROM users WHERE user_id='" . DB::escapeString($user_id) . "' LIMIT 1";
		else
		$sql = "SELECT * FROM users ORDER BY last_name";
		
		return DB::query($sql);
	}
	
	
	function newStaff($a)
	{
		// this should only be used when converting data, never when adding an new
		// user to an existing system
		if (!$a['user_id'])
		{
			$a['user_id'] = pl_new_id('users');
		}
		
		$sql = pl_build_sql("INSERT", "users", $a);
		DB::query($sql);
		
		$this->setPassword($a['user_id'], $a['password']);
		
		return $a['user_id'];
	}
	
	
	function updateStaff($a)
	{
		$sql = pl_build_sql("UPDATE", "users", $a);
		$result = DB::query($sql);
		
		if (isset($a['password']))
		{
			$this->setPassword($a['user_id'], $a['password']);
		}
		
		return true;
	}
	
	function updateUserPrefs($user_id, $pref_data)
	{
		global $auth_row;
		$pref_sql = '';
		$themes = array();
		
		// Only system users may edit other user's preferences
		if ('system' != $auth_row['group_id'])
		{
			$user_id = $auth_row['user_id'];
		}

	// Check for valid theme name.  $theme is used on an include(), so it must be carefully screened
	$dh = opendir('themes');
	while ($file = readdir($dh))
	{
		if ($file[0] != '.')
		{
			$themes[] = str_replace('.php', '', $file);
		}
	}

	closedir($dh);
	
	if (!in_array($pref_data['up_theme'], $themes))
	{
		$pref_data['up_theme'] = 'Blue';
	}		
		
		$a = array_merge($auth_row, $pref_data);
		
		foreach ($a as $key => $val)
		{
			if (substr($key, 0, 3) == 'up_')
			{
				$pref_sql .= "$key=$val,";
			}
		}

		$sql = "UPDATE users
			    SET session_data = '$pref_sql'
				WHERE user_id=$user_id LIMIT 1";	
		
		//echo $sql;
		
		$result = DB::query($sql);
		
		return true;
	}
	
	function setPassword($user_id, $password)
	{
		// bcrypt, not md5: pikaAuthDb verifies with password_verify() and
		// only falls back to md5 for pre-migration rows.
		$password_hash = password_hash($password, PASSWORD_DEFAULT);
		
		$sql = "UPDATE users SET password=? WHERE user_id=? LIMIT 1";
		$params = array($password_hash, $user_id);
		$result = DB::preparedQuery($sql, $params);
	}
	
	function fetchStaffArray()
	{
		$sql = "SELECT * FROM users ORDER BY last_name";
		$result = DB::query($sql);
		
		while ($row = DBResult::fetchRow($result))
		{
			$a[$row['user_id']] = "{$row['last_name']}, {$row['first_name']} {$row['middle_name']} {$row['extra_name']}";
		}
		
		return $a;
	}
	
	// returns only "active" staff - determined by who has login access enabled
	function fetchEnabledStaffArray()
	{
		$sql = "SELECT * FROM users where enabled=1 ORDER BY last_name";
		$result = DB::query($sql);
		
		while ($row = DBResult::fetchRow($result))
		{
			$a[$row['user_id']] = "{$row['last_name']}, {$row['first_name']} {$row['middle_name']} {$row['extra_name']}";
		}
		
		return $a;
	}
	
	// GROUPS
	function fetchGroups()
	{
		$sql = "SELECT * FROM `groups`";
		$result = DB::query($sql);
		
		return $result;
	}
	
	function getGroupsMenuArray()
	{
		$a = array();
		$sql = "SELECT group_id FROM `groups`";
		$result = DB::query($sql);
		
		while ($row = DBResult::fetchRow($result))
		{
			$a[$row['group_id']] = $row['group_id'];
		}
		
		return $a;
	}
	
	function addGroup($a)
	{
		$sql = pl_build_sql('INSERT', '`groups`', $a);
		$result = DB::query($sql);
		return $result;
	}
	
	function updateGroup($a)
	{
		$sql = pl_build_sql('UPDATE', '`groups`', $a);
		$result = DB::query($sql);
		return $result;
	}
	
	// PB ATTORNEYS
	
	function fetchPbAttorney($filter, &$pba_count, $first_row="", $list_length="")
	{
		$sql_filter = "";
		
		// Filter elements need to be escaped
		foreach ($filter as $key => $val)
		{
			$filter[$key] = DB::escapeString($val);
		}
		
		
		if (isset($filter['pba_id']) && $filter['pba_id'])
		{
			$sql = "SELECT * FROM pb_attorneys WHERE pba_id='{$filter['pba_id']}'
				    LIMIT 1";
		}
		else
		{
			if ($first_row && $list_length)
			{
				$sql_limit = " LIMIT " . (int) $first_row . ", " . (int) $list_length;
			}
			
			elseif ($list_length)
			{
				$sql_limit = " LIMIT " . (int) $list_length;
			}
			
			// handle filter options
			if (isset($filter['county']) && $filter['county'])
			{
				$sql_filter .= " AND county LIKE '%{$filter['county']}%'";
			}
			
			if (isset($filter['languages']) && $filter['languages'])
			{
				$sql_filter .= " AND languages LIKE \"%{$filter['languages']}%\"";
			}
			
			if (isset($filter['practice_areas']) && $filter['practice_areas'])
			{
				$sql_filter .= " AND practice_areas LIKE '%{$filter['practice_areas']}%'";
			}
			
			if (isset($filter['last_name']) && $filter['last_name'])
			{
				$sql_filter .= " AND last_name LIKE '%{$filter['last_name']}%'";
			}

			$sql = "SELECT count(*) FROM pb_attorneys WHERE 1" . $sql_filter;
			
			$result = DB::query($sql);
			
			$row = DBResult::fetchRow($result);
			
			$pba_count = $row["count(*)"];
			
			
			$sql = "SELECT * FROM pb_attorneys WHERE 1" . $sql_filter . " ORDER BY last_name, first_name" . $sql_limit;
		}
		
		return DB::query($sql);
	}
	
	
	
	function newPbAttorney($a)
	{
		global $plMenus;
		
		$a['pba_id'] = pl_new_id("pb_attorneys");
		
		$sql = pl_build_sql('INSERT', 'pb_attorneys', $a);
		$result = DB::query($sql);
		
		return $a['pba_id'];
	}
	
	
	function updatePbAttorney($a)
	{
		global $plMenus;
		
		$sql = pl_build_sql('UPDATE', 'pb_attorneys', $a);
		
		$result = DB::query($sql);
	}
	
	function fetchPbAttorneyArray()
	{
		$sql = "SELECT * FROM pb_attorneys ORDER BY last_name";
		$result = DB::query($sql);
		$a = array();  // make sure we return an empty array if no attys are found
		
		while ($row = DBResult::fetchRow($result))
		{
			$a[$row['pba_id']] = "{$row['last_name']}, {$row['first_name']} {$row['middle_name']} {$row['extra_name']}";
		}
		
		return $a;
	}
	
	function setPbAttorneyLastCase($pba_id, $last_case_date)
	{
		$lc = pl_mogrify_date($last_case_date);
		$sql = "UPDATE pb_attorneys SET last_case='" . DB::escapeString($lc)
			. "' WHERE pba_id='" . DB::escapeString($pba_id) . "' LIMIT 1";
		DB::query($sql);
	}
	
	
	
	// ACTIVITIES
	
	function fetchActivity($act_id='', $act_code='', $start_date='',
		$end_date='', $user_id='', $case_id='')
	{
		if ($act_id)
		{
			/*	$act_id went into the WHERE clause exactly as it arrived.
				Two callers in dataops.php hand this the raw POST body --
				one the 'act_id' field, one the keys of the 'hours' array --
				and pl_clean_form_input() in its default mode takes out only
				< and >, so a quote in either reached the statement intact
				and closed the string early.
				
				activities.act_id is int(11), so cast: an id that is not a
				number matches no row, which is the right answer for a
				lookup by primary key. ops/vcal.php:32 already grabs the
				same field in 'number' mode for this reason; now the
				function does not depend on each caller remembering.
			*/
			$act_id = (int) $act_id;
			
			$sql = "SELECT activities.*, cases.number FROM activities LEFT JOIN cases ON activities.case_id=cases.case_id WHERE act_id='$act_id' LIMIT 1";
			
			return DB::query($sql);
		}
		
		else if ($start_date && $end_date)
		{
			/*	Four values, all quoted, none escaped. Escape here rather
				than in the callers, the same choice
				fetchActivitiesCaseClient() makes.
			*/
			$start_date = DB::escapeString($start_date);
			$end_date = DB::escapeString($end_date);
			$case_id = DB::escapeString($case_id);
			$user_id = DB::escapeString($user_id);

			$sql = "SELECT *
		    FROM activities	
		    WHERE act_date>='$start_date'
		    AND act_date<='$end_date'";
			
			if ($case_id)
			{
				$sql .= " AND case_id='$case_id' ";
			}
			
			if ($user_id)
			{
				$sql .= " AND user_id='$user_id' ";
			}
			
			$sql .= ' ORDER BY user_id, act_time';
			
			// echo $sql;
			
			return DB::query($sql);
		}
		
		else
		{
			$sql = "SELECT *
				    FROM activities
				    WHERE act_code='" . DB::escapeString($act_code) . "'";
			return DB::query($sql);
		}
		
	}
	
	
	function fetchActivities($filter, &$contact_count, $order_field='act_date', $order='ASC',
	$first_row='0', $list_length='30')
	{
		/*	Escape every value once, here, the way fetchCaseList() and
			fetchPbAttorney() already do with their own filter arrays, so
			that a filter added later cannot be the one that gets
			forgotten.
		*/
		foreach ($filter as $filter_key => $filter_value)
		{
			if (is_scalar($filter_value))
			{
				$filter[$filter_key] = DB::escapeString((string) $filter_value);
			}
		}

		$sql = ' FROM activities WHERE 1';
		
		if (isset($filter["act_date"]) && $filter["act_date"])
		{
			if ('NULL' == $filter["act_date"])
			{
				$sql .= " AND act_date IS NULL";
			}
			
			else 
			{
				$sql .= " AND act_date='{$filter["act_date"]}'";
			}
		}
		
		if (isset($filter['user_id']) && $filter['user_id'])
		{
			$sql .= " AND activities.user_id='{$filter['user_id']}'";
		}
		
		if (isset($filter["starting"]) && $filter["starting"])
		{
			$sql .= " AND act_date >= '{$filter["starting"]}'";
		}
		
		if (isset($filter["ending"]) && $filter["ending"])
		{
			$sql .= " AND act_date <= '{$filter["ending"]}'";
		}
		
		if (isset($filter["funding"]) && $filter["funding"])
		{
			$sql .= " AND funding='{$filter["funding"]}'";
		}
		
		$result = DB::query('SELECT COUNT(*) AS count' . $sql);
		$r = DBResult::fetchRow($result);
		$contact_count = $r["count"];
		
		// next, re-run the query, and only retrieve the records that will be
		// displayed on this screen.
		if ($order_field == 'last_name' && $order)
		{
			$sql .= " ORDER BY last_name, first_name " . pl_safe_sort_direction($order);
		}
		
		else if ($order_field && $order)
		{
			$sql .= pl_safe_order_by($order_field, $order, 'activity sort column');
		}
		
		$sql .= " LIMIT " . (int) $first_row . ", " . (int) $list_length;
		
		$full_sql = 'SELECT act_id, act_date, act_time, act_end_time, hours, completed,
				user_id, case_id, category, funding, summary' . $sql;
		
		//echo $full_sql;
		
		return DB::query($full_sql);
	}
	
	
	function getActivitiesTodo($user_id)
	{
		$sql = "SELECT act_id, act_date, act_time, hours, completed, location, activities.funding,
		activities.user_id, category, summary, cases.case_id, number, client_id, last_name, 
		first_name, phone, area_code, phone_notes, act_type
		FROM activities 
		LEFT JOIN cases ON activities.case_id=cases.case_id 
		LEFT JOIN contacts ON cases.client_id=contacts.contact_id 
		WHERE activities.user_id=" . (int) $user_id . "
		AND act_date IS NULL
		AND completed = 0
		ORDER BY act_id ASC LIMIT 1000";
		
		return DB::query($sql);
	}
	
	
	function getActivitiesOverdue($user_id)
	{
		$act_date = date('Y-m-d');
		$act_time = date("H:i:00");  // 20121228 MDF
		
		$sql = "SELECT act_id, act_date, act_time, act_end_time, hours, completed, location, activities.funding,
		activities.user_id, category, summary, cases.case_id, number, client_id, last_name, 
		first_name, phone, area_code, phone_notes, act_type
		FROM activities 
		LEFT JOIN cases ON activities.case_id=cases.case_id 
		LEFT JOIN contacts ON cases.client_id=contacts.contact_id 
		WHERE activities.user_id=" . (int) $user_id . "
		AND act_type = 'K'
		AND (act_date < '$act_date' OR (act_date = '$act_date' && act_time <= '$act_time'))
		AND completed = 0
		ORDER BY act_date ASC, act_time ASC, act_id ASC LIMIT 1000";

		return DB::query($sql);
	}
	
	
	function getActivitiesPending($user_id, $act_date, $act_time = null)
	{
		if (is_null($act_date))
		{
			$act_date = date('Y-m-d');
		}
		
		$sql = "SELECT act_id, act_date, act_time, act_end_time, hours, completed, location, activities.funding,
		activities.user_id, category, summary, cases.case_id, number, client_id, last_name, 
		first_name, phone, area_code, phone_notes, act_type
		FROM activities 
		LEFT JOIN cases ON activities.case_id=cases.case_id 
		LEFT JOIN contacts ON cases.client_id=contacts.contact_id 
		WHERE activities.user_id=" . (int) $user_id . "
		AND act_date = '" . DB::escapeString($act_date) . "'";
		/*
				AND (act_date = '$act_date' OR 
			((repeat_period = 'D' AND DAYOFWEEK(act_date) != 1 AND DAYOFWEEK(act_date) !=7) OR
			(repeat_period = 'W' AND DAYOFWEEK('$act_date') = DAYOFWEEK(act_date)) OR
			(repeat_period = 'M' AND DAYOFMONTH('$act_date') = DAYOFMONTH(act_date)) OR
			(repeat_period = 'Y' AND DAYOFMONTH('$act_date') = DAYOFMONTH(act_date) AND MONTH('$act_date') = MONTH(act_date))
			))
			*/
		/* If a time is specified, consider any records scheduled before that time to be overdue,
		not pending. */
		if (!is_null($act_time))
		{
			$sql .= " AND (act_time > '" . DB::escapeString($act_time) . "' OR act_time IS NULL)";
		}
		
		$sql .= " AND completed = 0
		ORDER BY act_time ASC, act_id ASC LIMIT 1000";
		
		//echo $sql;
		
		/*
		(
select act_id AS table_id, 'activities' AS label, user_id, act_date, act_time
	FROM activities 
	WHERE act_date = '2003-07-04'
	AND user_id=43
) UNION (
select events.event_id AS table_id, 'events' AS label, user_id, CURRENT_DATE AS act_date, event_time AS act_time
	from events
	LEFT JOIN event_users ON events.event_id=event_users.event_id
	WHERE (user_id = 43 OR all_users = 1)
	AND ((repeat_period='D')
		OR
		(repeat_period='W' AND DAYOFWEEK(event_date) = DAYOFWEEK(NOW()))
		OR
		(repeat_period='M' AND DAYOFMONTH(event_date) = DAYOFMONTH(NOW()))
		OR
		(repeat_period='Y' AND DAYOFMONTH(event_date) = DAYOFMONTH(NOW()) AND MONTH(event_date) = MONTH(NOW()))
	)
) order by act_date ASC, act_time ASC;
*/
		//echo $sql;
		return DB::query($sql);
	}

	
	function getActivitiesCompleted($user_id, $act_date = null)
	{
		if (is_null($act_date))
		{
			$act_date = date('Y-m-d');
		}

		$sql = "SELECT act_id, act_date, act_time, act_end_time, hours, completed, location, activities.funding,
		activities.user_id, category, summary, cases.case_id, number, client_id, last_name, 
		first_name, phone, area_code, phone_notes, act_type
		FROM activities 
		LEFT JOIN cases ON activities.case_id=cases.case_id 
		LEFT JOIN contacts ON cases.client_id=contacts.contact_id 
		WHERE activities.user_id=" . (int) $user_id . "
		AND act_date = '" . DB::escapeString($act_date) . "'
		AND completed = 1
		ORDER BY act_time ASC, act_id ASC LIMIT 1000";
		return DB::query($sql);
	}
	
	
	function fetchActivitiesCaseClient($filter, &$contact_count, $order_field='act_date', 
		$order='ASC', $first_row='0', $list_length='30')
	{
		// Every value below arrives from the calendar's query string
		// through pl_grab_var(), which encodes < and > and nothing else --
		// a single quote passes straight through. These were interpolated
		// raw, so cal_week.php?user_id=office_' OR 1=1 -- was a working
		// injection. Escape at the point of interpolation rather than in
		// the callers, because six of them reach this method.
		$sql = ' FROM activities LEFT JOIN cases ON activities.case_id=cases.case_id LEFT JOIN contacts ON cases.client_id=contacts.contact_id WHERE 1';
		
		if (isset($filter["act_date"]) && $filter["act_date"])
		{
			$sql .= " AND act_date='" . DB::escapeString($filter["act_date"]) . "'";
		}
		
		if (isset($filter['user_list']) && is_array($filter['user_list']))
		{
			// The elements went into IN (...) unquoted, so this branch did
			// not even need a quote to be injectable. User ids are
			// integers; a non-numeric entry is a malformed request, so it
			// is dropped rather than escaped.
			$tmpa = "0";
			
			foreach ($filter['user_list'] AS $val)
			{
				if (is_numeric($val))
				{
					$tmpa .= ',' . (int) $val;
				}
			}
			
			$sql .= " AND activities.user_id IN ($tmpa)";
		}

		// The key is absent whenever the caller filters by anything else, so
		// this was an undefined array key rather than a false test.
		else if (!empty($filter['user_id']))
		{
			$sql .= " AND activities.user_id='" . DB::escapeString($filter['user_id']) . "'";
		}
		
		if ($filter["starting"])
		{
			$sql .= " AND act_date >= '" . DB::escapeString($filter["starting"]) . "'";
		}
		
		if ($filter["ending"])
		{
			$sql .= " AND act_date <= '" . DB::escapeString($filter["ending"]) . "'";
		}
		
		if (isset($filter['no_date']) && $filter['no_date'])
		{
			$sql .= " AND act_date IS NULL";
		}
		
		if (isset($filter["funding"]) && $filter["funding"])
		{
			$sql .= " AND activities.funding='" . DB::escapeString($filter["funding"]) . "'";
		}
		
		if (isset($filter["act_type"]) && $filter["act_type"])
		{
			$sql .= " AND act_type='" . DB::escapeString($filter["act_type"]) . "'";
		}
		
		if (isset($filter['completed']) && is_numeric($filter['completed']))
		{
			$sql .= " AND completed={$filter['completed']}";
		}
		
		if (isset($filter['office']) && strlen($filter['office']) > 0)
		{
			$sql .= " AND office='" . DB::escapeString($filter['office']) . "'";
		}

		if (isset($filter['number']) && strlen($filter['number']) > 0)
		{
			$sql .= " AND number LIKE '" . DB::escapeString($filter['number']) . "'";
		}
		
		if (isset($filter['category']) && strlen($filter['category']) > 0)
		{
			$e = explode(',', $filter['category']);
			foreach ($e as $key => $val)
			{
				$e[$key] = "'" . DB::escapeString(trim($val)) . "'";
			}
			$f = implode(', ', $e);
			
			$sql .= " AND category IN ({$f})";
		}


		$result = DB::query('SELECT COUNT(*) AS count' . $sql);
		$r = DBResult::fetchRow($result);
		$contact_count = $r["count"];
		
		// next, re-run the query, and only retrieve the records that will be
		// displayed on this screen.
		if ($order_field == 'last_name' && $order)
		{
			$sql .= " ORDER BY last_name, first_name " . pl_safe_sort_direction($order);
		}
		
		else if ($order_field == 'date-user-time' && $order)
		{
			$dir = pl_safe_sort_direction($order);
			$sql .= " ORDER BY act_date $dir, user_id $dir, act_time $dir";
		}
			
		else if ($order_field && $order)
		{
			$sql .= pl_safe_order_by($order_field, $order, 'activity sort column');
		}
		
		$sql .= " LIMIT " . (int) $first_row . ", " . (int) $list_length;
		
		$full_sql = 'SELECT act_id, act_type, act_date, act_time, act_end_time, hours, completed, location, activities.funding,
				activities.user_id, category, summary, cases.case_id, number, office, client_id, last_name, first_name, phone, area_code, phone_notes' . $sql;
		
		return DB::query($full_sql);
	}
	
	
	function newActivity($a)
	{
		global $plSettings;
		global $auth_row;
		
		$act_interval = (int) $plSettings['act_interval'];
		
		$a["act_id"] = pl_new_id('activities');
		$a['hours'] = pika_round_decimal_hours($a['hours'], $act_interval);
		
		if (!isset($a['user_id']) && !isset($a['pba_id']))
		{
			$a['user_id'] = $auth_row['user_id'];
		}
		
		/*
		Round off 'hours' based on act_interval, if hours were entered,
		and if a valid act_interval was specified.
		*/
		/*
		if ($a['hours'] > 0 && $act_interval > 0)
		{
			// the number of hours
			$hours = floor($a['hours']);
			// the number of minutes
			$minutes = ($a['hours'] - $hours) * 60.0;
			// the rounded number of minutes
			$rounded_minutes = ((int) ($minutes / $act_interval)) * $act_interval / 60;
			
			$a['hours'] = $hours + $rounded_minutes;
			
			
			//If the number of hours and minutes rounded down to zero, set 'hours'
			//to the minimum amount of minutes.
			
			if (0 == $a['hours'])
			{
				$a['hours'] = $act_interval / 60;
			}
		}
		*/
		
		$sql = pl_build_sql('INSERT', 'activities', $a);
		$result = DB::query($sql);
		
		// echo $sql;
		
		return $a["act_id"];
	}
	
	
	function updateActivity($a)
	{
		global $plSettings;
		
		if (!isset($a['hours']))
		{
			$a['hours'] = null;
		}
		
		$act_interval = (int) $plSettings['act_interval'];
		$a['hours'] = pika_round_decimal_hours($a['hours'], $act_interval);

		/*
		Round off 'hours' based on act_interval, if hours were entered,
		and if a valid act_interval was specified.
		*/
/*		if ($a['hours'] > 0 && $act_interval > 0)
		{
			// the number of hours
			$hours = floor($a['hours']);
			// the number of minutes
			$minutes = ($a['hours'] - $hours) * 60.0;
			// the rounded number of minutes
			$rounded_minutes = ((int) ($minutes / $act_interval)) * $act_interval / 60;
			
			$a['hours'] = $hours + $rounded_minutes;
			
			
			If the number of hours and minutes rounded down to zero, set 'hours'
			to the minimum amount of minutes.
			
			if (0 == $a['hours'])
			{
				$a['hours'] = $act_interval / 60;
			}
		}
		*/
		$sql = pl_build_sql('UPDATE', 'activities', $a);
		$result = DB::query($sql);
	}
	
	
	function duplicateActivity($act_id, $override_vals)
	{
		$result = $this->fetchActivity($act_id);
				
		return $this->newActivity(array_merge(DBResult::fetchRow($result), $override_vals));
	}

	
	function searchActivity($s)
	{
		$a = explode(' ', $s);
		$a_count = sizeof($a);

		/*	Each word goes inside a LIKE pattern in a quoted string. The
			search box reaches this through pl_grab_var(), so a quote
			arrives intact.
		*/
		foreach ($a as $a_key => $a_val)
		{
			$a[$a_key] = DB::escapeString($a_val);
		}
		
		$sql = "SELECT *
			    FROM activities
			    WHERE notes LIKE '%{$a[0]}%'";
		
		for($i = 1; $i < $a_count; $i++)
		$sql .= " AND notes LIKE '%{$a[$i]}%'";
		
		return DB::query($sql);
	}
	
	
	function deleteActivity($act_id='')
	{
		$sql = "DELETE FROM activities WHERE act_id=" . (int) $act_id . " LIMIT 1";
		return DB::query($sql);
	}
	
	
	
	// MOTD
	
	function fetchMotd($motd_id='')
	{
		if ($motd_id)
		{
			$sql = "SELECT * FROM motd WHERE motd_id=" . (int) $motd_id . " LIMIT 1";
			return DB::query($sql);
		}
		
		else
		{
			$sql = "SELECT motd.*, users.* FROM motd LEFT JOIN users ON motd.user_id=users.user_id";
			return DB::query($sql);
		}
	}
	
	
	function newMotd($a)
	{
		$motd_id = pl_new_id('motd');
		$a["motd_id"] = $motd_id;
		$result = DB::query(pl_build_sql('INSERT', 'motd', $a));
	}
	
	
	function updateMotd($a)
	{
		$result = DB::query(pl_build_sql('UPDATE', 'motd', $a));
	}
	
	
	function deleteMotd($a)
	{
		$result = DB::query("DELETE FROM motd WHERE motd_id=" . (int) $a . " LIMIT 1");
	}
	
	
	function fetchCompens($case_id)
	{
		$sql = "SELECT compens.*
						FROM compens
						WHERE compens.case_id=" . (int) $case_id;
		return DB::query($sql);
	}

	
	function addCompen($data)
	{
		$data['compen_id'] = pl_new_id('compens');
		$sql = pl_build_sql('INSERT', 'compens', $data);
		
		return DB::query($sql);
	}

	
	/*	The five case_charges methods were removed here.
		
		Their only callers were the two dead criminal-charges handlers in
		dataops.php, which are gone; see the note there. Each one built SQL by
		interpolating its arguments, and those arguments came straight from the
		request, so leaving them in place would have kept the injection one
		future caller away. new_install.sql creates neither table they query.
	*/
	
	function fetchSurveyQuestions()
	{
		$a = array();
		$sql = "SELECT * FROM survey_questions LIMIT 50";
		
		$result = DB::query($sql);
		
		while ($row = DBResult::fetchRow($result))
		{
			$a[] = $row;
		}
		
		return $a;
	}
	
	function addSurveyResponse($q_id, $case_id, $answer)
	{
		if (!is_numeric($q_id) || !is_numeric($case_id))
		{
			return false;
		}
		
		$a_id = pl_new_id('survey_answers');
		
		/*	$q_id and $case_id are checked as numbers above and $a_id comes
			from pl_new_id(); the answer text is the one value that arrives
			from the request.
		*/
		$sql = "INSERT INTO survey_answers SET a_id=" . (int) $a_id . ", q_id=" . (int) $q_id
			. ", case_id=" . (int) $case_id . ", answer='" . DB::escapeString($answer) . "'";
		
		DB::query($sql);
		
		return true;
	}
	
	
}
?>
