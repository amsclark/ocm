<?php

/**********************************/
/* Pika CMS (C) 2009 Aaron Worley */
/* written by: Matthew Friedlander*/
/* http://www.pikasoftware.com    */
/**********************************/

require_once('plBase.php');


/**
* Something.
*
* @author Aaron Worley <amworley@pikasoftware.com>;
* @version 1.0
* @package Danio
*/
class pikaRssFeed extends plBase 
{
	/*	The only tags a feed body is allowed to keep, and the two that are
		dropped whole rather than reduced to their text.
	*/
	private static $safe_html_tags = array('a' => true, 'ul' => true, 'ol' => true, 'li' => true, 'p' => true);
	private static $safe_html_drop = array('script' => true, 'style' => true);
	
	public function __construct($feed_id = null)
	{
		$this->db_table = 'rss_feeds';
		parent::__construct($feed_id);
		if(strlen($this->feed_cache) > 0) {
			$this->feed_cache = stripslashes($this->feed_cache);
		}
		if(is_null($feed_id)) {
			// New record
			$this->created = date('YmdHis');
		} 
	}
	
	public function save($show_sql = false) {
		$this->feed_cache = addslashes($this->feed_cache);
		parent::save($show_sql);
	}
	
	public static function getRssDB() {
		$result_array = array();
		$result = DB::query("SELECT rss_feeds.* FROM rss_feeds WHERE 1;");
		while ($row = DBResult::fetchRow($result)) {
			$row['feed_cache'] = stripslashes($row['feed_cache']);
			$result_array[] = $row;
		}
		return $result_array;
	}
	
	public static function updateFeeds() {
		$result = self::getRssDB();
		$current_timestamp = pl_mysql_timestamp_to_unix(date('YmdHis'));
		
		foreach ($result as $row) {
			if($row['enabled']) {
				$last_modified = pl_mysql_timestamp_to_unix($row['last_modified']);
				//echo $current_timestamp - $last_modified;
				if(strlen($row['feed_cache']) < 1 || ($current_timestamp - $last_modified) > 3600) {
					/*	A feed URL is a stored value, so the scheme is checked
						before it is fetched. file_get_contents() reads any
						scheme PHP knows: file:// and php:// turned this into
						a way to read a local file and draw it on the home
						page, and any other scheme made the server fetch a
						host of the author's choosing.
					*/
					if(!preg_match('/^https?:\/\//i',(string) $row['feed_url'])) {
						continue;
					}
					// Set timeout to 3 seconds (otherwise when it errors it sits for the full 30 sec script timeout)
					$rss_stream_context = stream_context_create(array('http' => array('timeout' => 3)));
					$feed_cache = @file_get_contents($row['feed_url'],false,$rss_stream_context);
					$doc = self::loadFeedDocument($feed_cache);
					$feed = new pikaRssFeed($row['feed_id']);
					$feed->last_modified = date('YmdHis');
					if($doc) {
						$feed->feed_cache = $doc->saveXML();
					}
					elseif(strlen($row['feed_cache']) < 1) {
						/*	A cache that stays empty makes every page load try
							the fetch again, so a note goes in to keep the
							hourly back-off. A good cache is left alone: a
							failed fetch used to overwrite it.
						*/
						$feed->feed_cache = '<!-- pikaRssFeed: the last fetch of this feed failed. -->';
					}
					$feed->save();
				}
			}
		}
	}
	
	public static function getFeeds() {
		self::updateFeeds();
		$result = self::getRssDB();
		$feeds_array = array();
		foreach ($result as $row) {
			if($row['enabled']) {
				$feed_type = $row['feed_type'];
				$feed_cache = $row['feed_cache'];
				if($feed_type != 1 && $feed_type != 2) {
					
					$feed_type = self::feedType($feed_cache);
					
					
					if($feed_type) {
						$feed = new pikaRssFeed($row['feed_id']);
						$feed->feed_type = $feed_type;
						$feed->save();
						
					}
				}
				$feed_array = array();
				if($feed_type == 1) {
					$feed_array = self::parseRSS($feed_cache,$row['list_limit']);
				}
				if($feed_type == 2) {
					
					$feed_array = self::parseATOM($feed_cache,$row['list_limit']);
				}
				if($feed_type == 3) {
					
					$feed_array = self::parseRDF($feed_cache,$row['list_limit']);
				}
				if(isset($feed_array['title']) && $feed_array['title']) {
					$feeds_array[] = $feed_array;
				}
			}
		}
		return $feeds_array;
	}
	
	public static function feedType($feed_cache = null) {
		// Returns 1 (RSS), 2 (ATOM), 3 (RDF), or false
		
		$doc = self::loadFeedDocument($feed_cache);
		
		if($doc) {
			
			$xpath = new DOMXPath($doc);
			$channels = $xpath->query('/rss/channel');
			
			if ($channels->length >= 1) {
				return 1;
			}
			$xpath = new DOMXPath($doc);
			$xpath->registerNameSpace('atom', 'http://www.w3.org/2005/Atom');

			$feeds = $xpath->query('/atom:feed');
			if ($feeds->length >= 1) {
				return 2;
			}
			
			$xpath = new DOMXPath($doc);
			$xpath->registerNameSpace('rss', 'http://my.netscape.com/rdf/simple/0.9/');
			$channels = $xpath->query('/rdf:RDF/rss:channel');
			if ($channels->length >= 1) {
				return 3;
			}
			
		}
		return false;
	}
	public static function parseRSS($feed_cache = null, $limit = 0) {
		$feed_array = array();
		$doc = self::loadFeedDocument($feed_cache);
		if($doc) {
			$xpath = new DOMXPath($doc);
			$title = self::nodeText($xpath,'/rss/channel/title');
			$items = $xpath->query('/rss/channel/item');
			$feed_array['title'] = $title;
			foreach ($items as $item) {
				$title = self::nodeText($xpath,'title',$item);
				$content = self::nodeText($xpath,'description',$item);
				$link = self::nodeText($xpath,'link',$item);
				$feed_array['entries'][] = array('title' => $title, 'content' => $content, 'link' => $link);
			}
		}
		if(!isset($feed_array['entries']) || !is_array($feed_array['entries'])) {
			/*	A feed with a title and no items left this key unset, and
				count(null) is fatal on PHP 8 - one such feed answered the
				whole home page with an empty HTTP 500.
			*/
			$feed_array['entries'] = array();
		}
		if($limit && is_numeric($limit) && count($feed_array['entries']) > $limit) {
			$feed_array['entries'] = array_slice($feed_array['entries'],0,$limit);
		}
		return $feed_array;
	}
	public static function parseATOM($feed_cache = null, $limit = 0) {
		$feed_array = array();
		$doc = self::loadFeedDocument($feed_cache);
		if($doc) {
			$xpath = new DOMXPath($doc);
			$xpath->registerNameSpace('atom', 'http://www.w3.org/2005/Atom');
			$title = self::nodeText($xpath,'/atom:feed/atom:title');
			$entries = $xpath->query('/atom:feed/atom:entry');
			$feed_array['title'] = $title;
			foreach ($entries as $entry) {
				$title = self::nodeText($xpath,'atom:title',$entry);
				$content = self::nodeText($xpath,'atom:content',$entry);
				$link = self::nodeText($xpath,"atom:link[@rel='alternate']/@href",$entry);
				$feed_array['entries'][] = array('title' => $title, 'content' => $content, 'link' => $link);
			}
		}
		if(!isset($feed_array['entries']) || !is_array($feed_array['entries'])) {
			/*	A feed with a title and no items left this key unset, and
				count(null) is fatal on PHP 8 - one such feed answered the
				whole home page with an empty HTTP 500.
			*/
			$feed_array['entries'] = array();
		}
		if($limit && is_numeric($limit) && count($feed_array['entries']) > $limit) {
			$feed_array['entries'] = array_slice($feed_array['entries'],0,$limit);
		}
		return $feed_array;
	}
	public static function parseRDF($feed_cache = null, $limit = 0) {
		$feed_array = array();
		$doc = self::loadFeedDocument($feed_cache);
		if($doc) {
			$xpath = new DOMXPath($doc);
			$xpath->registerNameSpace('rss', 'http://my.netscape.com/rdf/simple/0.9/');
			$title = self::nodeText($xpath,'/rdf:RDF/rss:channel/rss:title');
			$items = $xpath->query('/rdf:RDF/rss:item');
			$feed_array['title'] = $title;
			foreach ($items as $item) {
				$title = self::nodeText($xpath,'rss:title',$item);
				$content = self::nodeText($xpath,'rss:description',$item);
				$link = self::nodeText($xpath,'rss:link',$item);
				$feed_array['entries'][] = array('title' => $title, 'content' => $content, 'link' => $link);
			}
		}
		if(!isset($feed_array['entries']) || !is_array($feed_array['entries'])) {
			/*	A feed with a title and no items left this key unset, and
				count(null) is fatal on PHP 8 - one such feed answered the
				whole home page with an empty HTTP 500.
			*/
			$feed_array['entries'] = array();
		}
		if($limit && is_numeric($limit) && count($feed_array['entries']) > $limit) {
			$feed_array['entries'] = array_slice($feed_array['entries'],0,$limit);
		}
		return $feed_array;
	}
	
	/**
	 * Parse feed XML, or return false.
	 *
	 * A feed comes from a third party, so the document is refused rather
	 * than trusted. A DOCTYPE can declare an entity that reads a local file
	 * or that expands until the request runs out of memory, and LIBXML_NONET
	 * stops the parser resolving anything over the network. This is the same
	 * rule pikaLSXML_V2 applies to an uploaded document.
	 *
	 * Returning false instead of throwing keeps a malformed feed from
	 * breaking the whole home page, and holding the libxml errors here keeps
	 * a broken feed from filling the error log on every page load.
	 */
	private static function loadFeedDocument($xml_text = null)
	{
		if(is_null($xml_text) || strlen($xml_text) < 1) {
			return false;
		}
		
		if(preg_match('/<!DOCTYPE/i',$xml_text)) {
			return false;
		}
		
		$doc = new DOMDocument();
		$doc->preserveWhiteSpace = true;
		
		$previous_errors = libxml_use_internal_errors(true);
		$loaded = $doc->loadXML($xml_text,LIBXML_NONET);
		libxml_clear_errors();
		libxml_use_internal_errors($previous_errors);
		
		if(!$loaded) {
			return false;
		}
		
		return $doc;
	}
	
	/*	A missing node makes ->item(0) null, and reading ->nodeValue off it
		is fatal on PHP 8. Every feed field is read through here instead.
	*/
	private static function nodeText($xpath, $query, $context = null)
	{
		$nodes = is_null($context) ? $xpath->query($query) : $xpath->query($query,$context);
		if(!$nodes || $nodes->length < 1) {
			return '';
		}
		return (string) $nodes->item(0)->nodeValue;
	}
	
	/**
	 * Rebuild a feed body as markup this function wrote itself.
	 *
	 * strip_tags() with an allowed list keeps every attribute on the tags it
	 * keeps, so <a onmouseover="..."> and <a href="javascript:..."> both
	 * reached the page. This parses the fragment and writes it out again:
	 * only <a><ul><ol><li><p> survive, the only attribute that can come with
	 * them is an href that safeUrl() accepted, all text is escaped, and any
	 * other tag is reduced to its text (or dropped, for script and style).
	 */
	public static function safeHtml($html = null)
	{
		$html = (string) $html;
		if(strlen($html) < 1) {
			return '';
		}
		
		$doc = new DOMDocument();
		$wrapper = '<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8">' .
				   '</head><body><div id="pl-feed-body">' . $html . '</div></body></html>';
		
		$previous_errors = libxml_use_internal_errors(true);
		$loaded = $doc->loadHTML($wrapper,LIBXML_NONET);
		libxml_clear_errors();
		libxml_use_internal_errors($previous_errors);
		
		if(!$loaded) {
			return pl_html_escape($html);
		}
		
		$body = $doc->getElementById('pl-feed-body');
		if(is_null($body)) {
			return pl_html_escape($html);
		}
		
		return self::safeHtmlChildren($body);
	}
	
	private static function safeHtmlChildren($node)
	{
		$safe_html = '';
		foreach ($node->childNodes as $child) {
			$safe_html .= self::safeHtmlNode($child);
		}
		return $safe_html;
	}
	
	private static function safeHtmlNode($node)
	{
		if($node->nodeType == XML_TEXT_NODE || $node->nodeType == XML_CDATA_SECTION_NODE) {
			return pl_html_escape($node->nodeValue);
		}
		
		if($node->nodeType != XML_ELEMENT_NODE) {
			// A comment, a processing instruction, a doctype: nothing to draw.
			return '';
		}
		
		$tag_name = strtolower($node->nodeName);
		
		if(isset(self::$safe_html_drop[$tag_name])) {
			return '';
		}
		
		$inner_html = self::safeHtmlChildren($node);
		
		if(!isset(self::$safe_html_tags[$tag_name])) {
			// Not an allowed tag - keep the words, drop the tag.
			return $inner_html;
		}
		
		$open_tag = $tag_name;
		if($tag_name == 'a') {
			$href = self::safeUrl($node->getAttribute('href'));
			if(strlen($href) > 0) {
				$open_tag .= ' href="' . pl_html_escape($href) . '"';
			}
		}
		
		return "<{$open_tag}>{$inner_html}</{$tag_name}>";
	}
	
	/**
	 * Return a link a browser can follow, or an empty string.
	 *
	 * The leading control and space characters go first, because a browser
	 * ignores them and would read "java\nscript:alert(1)" as a scheme this
	 * function never saw. Only http, https and mailto are accepted.
	 */
	public static function safeUrl($url = null)
	{
		$url = preg_replace('/[\x00-\x20\x7F]+/','',(string) $url);
		
		if(preg_match('/^https?:\/\//i',$url) || preg_match('/^mailto:/i',$url)) {
			return $url;
		}
		
		return '';
	}
}

?>