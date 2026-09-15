<?php

/***********************************/
/* Pika CMS (C) 2010 Pika Software */
/* http://pikasoftware.com         */
/***********************************/

/**
* class pikaPrefs - Loads and retrieves pika user preferences
* @author Matthew Friedlander <matt@pikasoftware.com>;
* @version 1.0
* @package Danio
**/

require_once('pikaFileArray.php');

class pikaDefPrefs extends pikaFileArray  
{
	private static $instance;
	
	/*	The four font sizes cms/pika_cms.php knows how to draw. Both
		preference screens offer this list, and a value that is not on it
		is a missing array key when the page is built.
	*/
	private static $font_sizes = array('Small', 'Medium', 'Large', 'Super Size');
	
	/*	Every preference the two preference screens can save. Both handlers
		accept only these names from a POST, and initPrefs() reads back only
		these names, so a preference cannot be saveable but unrestorable.
	*/
	private static $pref_names = array('def_office',
										'def_intake_type',
										'intake',
										'def_relation_code',
										'paging',
										'font_size',
										'popup',
										'theme',
										'def_ical_interval',
										'r_format');
	
	protected function __construct()
	{
		$this->file_location = PL_DEFAULT_PREFS_FILE;
		parent::__construct();
	}
	
	public static function getInstance()
	{
		if(empty(self::$instance)) 
		{
			self::$instance = new self();
		} 
		return self::$instance;
	}
	
	
	/**
	 * public function initPrefs()
	 * 
	 * This function is meant to replace the legacy pl_session_set_default calls
	 * by instantiating all default preferences into the $_SESSION variable at
	 * runtime.  This will alleviate the need to iteratively call each value.
	 *
	 */
	public function initPrefs($user_id = null)
	{
		$user_prefs = array();
		
		if(!is_null($user_id) && is_numeric($user_id))
		{
			require_once(dirname(__FILE__) . '/pikaUser.php');
			$user = new pikaUser($user_id);
			$user_prefs = $user->getUserPrefs();
			foreach ($this->values as $name => $value)
			{
				if(!isset($user_prefs[$name]) || !$user_prefs[$name])
				{
					$user_prefs[$name] = $value;
				}
			}
			$user->session_data = serialize($user_prefs);
			$user->save();
		}
		
		/*	Read back every preference a preference screen can save, not only
			the ones the defaults file happens to carry. r_format and intake
			are saveable and are not in that file, so they were stored and
			then never read back.
			
			The list is fixed rather than taken from the stored array. That
			array comes out of the database, and a stray key left by an older
			install would otherwise overwrite an unrelated session value.
		*/
		$restore = array_keys($this->values);
		
		foreach (self::$pref_names as $name)
		{
			if (!in_array($name, $restore, true))
			{
				$restore[] = $name;
			}
		}
		
		foreach ($restore as $name)
		{
			if (isset($user_prefs[$name]))
			{
				$_SESSION[$name] = $user_prefs[$name];
			}
		}
		
	}
	
	/**
	 * public static function storePrefs()
	 * 
	 * Writes the preferences a handler was posted to the session and to the
	 * user's stored preferences. Both handlers used to write the session
	 * only, so every saved preference was lost at logout: initPrefs() reads
	 * users.session_data back on the next login and overwrote it.
	 * 
	 * $values is name => raw posted value. A value filterValue() refuses is
	 * skipped, which leaves whatever the preference already held.
	 * 
	 * @return bool whether anything was accepted
	 * @param user_id int
	 * @param values array
	 */
	public static function storePrefs($user_id, $values)
	{
		if (!is_array($values))
		{
			return false;
		}
		
		$user = null;
		$stored = array();
		
		if (!is_null($user_id) && is_numeric($user_id))
		{
			require_once(dirname(__FILE__) . '/pikaUser.php');
			$user = new pikaUser($user_id);
			$stored = $user->getUserPrefs();
		}
		
		$accepted = false;
		
		foreach ($values as $name => $value)
		{
			if (!in_array($name, self::$pref_names, true))
			{
				continue;
			}
			
			$filtered = self::filterValue($name, $value);
			
			if (is_null($filtered))
			{
				continue;
			}
			
			$_SESSION[$name] = $filtered;
			$stored[$name] = $filtered;
			$accepted = true;
		}
		
		if ($accepted && !is_null($user))
		{
			$user->session_data = serialize($stored);
			$user->save();
		}
		
		return $accepted;
	}
	
	/**
	 * public static function filterValue()
	 *
	 * Returns $value when it is something the named preference is allowed
	 * to hold, and null when it is not.
	 *
	 * A preference is a request value that gets stored and is then used
	 * without any further check. The theme name reaches include() in
	 * cms/pika_cms.php, the paging count is interpolated into a LIMIT
	 * clause in pika_get_attorneys(), the font size is used as an array
	 * key, and every value in the defaults file is written into PHP source
	 * by pikaFileArray::array2Php(). Checking the value where it is stored
	 * covers all of those at once, which is why every screen that writes a
	 * preference calls this.
	 *
	 * @return string|null
	 * @param name string
	 * @param value mixed
	 */
	public static function filterValue($name, $value)
	{
		if (is_null($value) || is_array($value) || is_object($value))
		{
			return null;
		}
		
		$value = (string) $value;
		
		switch ($name)
		{
			case 'theme':
				/*	cms/pika_cms.php includes themes/<name>.php, so the
					name has to be a plain word that really does name one
					of the files in that directory. A name holding '../'
					used to be followed.
				*/
				if (preg_match('/^[A-Za-z0-9_ -]+$/', $value)
					&& is_file(__DIR__ . "/../../themes/{$value}.php"))
				{
					return $value;
				}
				
				return null;
			
			case 'font_size':
				if (in_array($value, self::$font_sizes, true))
				{
					return $value;
				}
				
				return null;
			
			case 'r_format':
				if ($value === 'pdf' || $value === 'html')
				{
					return $value;
				}
				
				return null;
			
			case 'paging':
			case 'def_ical_interval':
				/*	A row count and a day count. Digits only: no sign, no
					space, and nothing that could be read as SQL.
				*/
				if (strlen($value) > 0 && ctype_digit($value))
				{
					return $value;
				}
				
				return null;
			
			case 'popup':
				return $value ? '1' : '0';
		}
		
		/*	Any other name is a preference an installation added for itself.
			Keep it, but only as one line of ordinary text: nothing that
			reads a preference expects a control character, and the
			defaults file writes each value into PHP source.
		*/
		if (strlen($value) > 255 || preg_match('/[\x00-\x1F\x7F]/', $value))
		{
			return null;
		}
		
		return $value;
	}
	
	/**
	 * public static function fontSizes()
	 *
	 * @return array
	 */
	public static function fontSizes()
	{
		return self::$font_sizes;
	}
}