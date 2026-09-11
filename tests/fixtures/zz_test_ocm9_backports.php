<?php
// CLI regression checks. The database stubs never connect or persist data.
if (PHP_SAPI !== 'cli') {
    http_response_code(403);
    exit;
}

$cms = getenv('OCM_TEST_CMS_DIR') ?: '/var/www/html/cms';
set_error_handler(function ($severity, $message, $file, $line) {
    throw new ErrorException($message, 0, $severity, $file, $line);
});

class ContactWrite extends RuntimeException
{
    public $values;
    public function __construct($values) { $this->values = $values; }
}

class DB
{
    public static $calls = array();
    public static $rows = array();
    public static function preparedQuery($sql, $params)
    {
        self::$calls[] = array($sql, $params);
        return self::$rows;
    }
    public static function query($sql)
    {
        throw new RuntimeException('Unexpected unbound query');
    }
}

class DBResult
{
    public static function numRows($rows) { return count($rows); }
    public static function fetchRow($rows) { return $rows[0]; }
}

function pl_new_id($table) { return 123; }
function _pika_first_name_only($name) { return $name; }
function pl_build_sql($operation, $table, $values)
{
    // Capture the completed lookup, but stop before the write and alias work.
    throw new ContactWrite($values);
}

require $cms . '/app/extralib/lib/pikaCms.php';
require $cms . '/pl_report.php';

// Prevent the retired RTF writer from creating relative output files.
if (!chdir('/proc')) {
    throw new RuntimeException('Cannot enter the read-only test directory');
}

// Old PDF code must fail before creating a file or invoking a converter.
define('PL_TMP_PATH', '/dev/null/ocm-backport-tests');
$passed = 0;
$failed = 0;
function check_backport($label, $test)
{
    global $passed, $failed;
    try {
        $test();
        echo "  ok   $label\n";
        $passed++;
    } catch (Throwable $error) {
        echo "  FAIL $label: " . $error->getMessage() . "\n";
        $failed++;
    }
}
function same_backport($actual, $expected, $label)
{
    if ($actual !== $expected) {
        throw new RuntimeException($label);
    }
}

$pk = new pikaCms;
foreach (array('27', '0 OR 1=1') as $case_id) {
    check_backport('fetchCase binds case ID ' . $case_id, function () use ($pk, $case_id) {
        DB::$calls = array();
        DB::$rows = array(array('case_id' => '27'));
        same_backport($pk->fetchCase($case_id), DB::$rows, 'case result changed');
        same_backport(DB::$calls, array(array('SELECT * FROM cases WHERE case_id=? LIMIT 1', array($case_id))), 'case ID was not bound');
    });
}
foreach (array('CASE-27', "CASE' OR '1'='1") as $number) {
    check_backport('fetchCase binds case number ' . $number, function () use ($pk, $number) {
        DB::$calls = array();
        DB::$rows = array(array('number' => $number));
        same_backport($pk->fetchCase('', $number), DB::$rows, 'case result changed');
        same_backport(DB::$calls, array(array('SELECT * FROM cases WHERE number=? LIMIT 1', array($number))), 'case number was not bound');
    });
}

foreach (array('newContact', 'updateContact') as $method) {
    foreach (array('zip', 'city') as $lookup) {
        foreach (array(false, true) as $attack) {
            $label = "$method binds $lookup " . ($attack ? 'SQL-shaped input' : 'and keeps address autofill');
            check_backport($label, function () use ($pk, $method, $lookup, $attack) {
                $a = array('first_name' => 'Zz', 'middle_name' => '', 'extra_name' => '',
                    'last_name' => 'Backport', 'contact_id' => '123', 'county' => '',
                    'zip' => '', 'city' => '', 'state' => '');
                DB::$calls = array();
                DB::$rows = $attack ? array() : array(array('zip' => '12345',
                    'city' => 'Smokeville', 'state' => 'NY', 'county' => 'Example'));
                if ($lookup === 'zip') {
                    $a['zip'] = $attack ? "' OR '1'='1" : ($method === 'updateContact' ? '12345-6789' : '12345');
                    $bound_zip = $method === 'updateContact' ? substr($a['zip'], 0, 5) : $a['zip'];
                    $expected = array('SELECT * FROM zip_codes WHERE zip=?', array($bound_zip));
                } else {
                    $a['city'] = $attack ? "Smokeville' OR 1=1 -- " : 'Smokeville';
                    $a['state'] = $attack ? "NY' OR 1=1 -- " : 'NY';
                    $expected = array('SELECT * FROM zip_codes WHERE city=? AND state=?', array($a['city'], $a['state']));
                }
                try {
                    $pk->$method($a);
                    throw new RuntimeException('contact did not reach the write boundary');
                } catch (ContactWrite $write) {
                    same_backport(DB::$calls, array($expected), 'lookup did not bind the exact input');
                    if (!$attack) {
                        same_backport($write->values['city'], 'Smokeville', 'city autofill changed');
                        same_backport($write->values['state'], 'NY', 'state autofill changed');
                        same_backport($write->values['county'], 'Example', 'county autofill changed');
                        same_backport($write->values['zip'], $lookup === 'zip' ? $a['zip'] : '12345', 'ZIP autofill or ZIP+4 changed');
                    } else {
                        same_backport($write->values['county'], '', 'unmatched input populated an address');
                    }
                }
            });
        }
    }
}

check_backport('reports default to HTML', function () {
    same_backport((new pikaReport)->format, 'html', 'default report format is not HTML');
});
foreach (array('html', 'pdf', 'rtf') as $format) {
    check_backport('report display handles ' . $format . ' without a converter', function () use ($format) {
        $report = new pikaReport;
        $report->setFormat($format);
        ob_start();
        try {
            $report->display('<p>Report body</p>');
            $output = ob_get_contents();
        } finally {
            ob_end_clean();
        }
        same_backport($output, $format === 'html' ? '<p>Report body</p>' : '', 'unexpected report output');
    });
}
check_backport('unused plWebDoc is removed', function () use ($cms) {
    same_backport(file_exists($cms . '/app/extralib/lib/plWebDoc.php'), false, 'legacy report builder still exists');
});

echo "OCM9 backports: $passed passed, $failed failed\n";
exit($failed === 0 ? 0 : 1);
