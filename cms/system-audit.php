<?php

/***********************************/
/* OCM                             */
/* Security audit log viewer.      */
/*                                 */
/* System-group admins only. The   */
/* page is read-only — there is no */
/* supported path to edit or       */
/* delete audit_log rows from the  */
/* application.                    */
/***********************************/

require_once('pika-danio.php');
pika_init();
require_once('pikaSettings.php');
require_once('pikaTempLib.php');

$main_html = $html = array();
$base_url = pl_settings_get('base_url');
$branding = pl_settings_get('owner_name');

$main_html['page_title'] = $page_title = 'Audit Log';
$main_html['nav'] = "<a href=\"{$base_url}/\">{$branding} Home</a> &gt; "
                  . "<a href=\"{$base_url}/site_map.php\">Site Map</a> &gt; {$page_title}";

if (!pika_authorize('system', array())) {
    $main_html['content'] = 'Access denied';
    $default_template = new pikaTempLib('templates/default.html', $main_html);
    pika_exit($default_template->draw());
}

// ── Filters (all optional, all validated) ───────────────────────────────
$filter_action   = pl_grab_get('action');
$filter_username = pl_grab_get('username');
$filter_user_id  = pl_grab_get('user_id', null, 'number');
$filter_days     = pl_grab_get('days', null, 'number');
$page            = pl_grab_get('page', null, 'number');

if (!is_numeric($page) || $page < 1) {
    $page = 1;
}
$per_page = 100;
$offset   = ((int)$page - 1) * $per_page;

$where   = array();
$params  = array();
if (is_string($filter_action) && preg_match('/^[a-z0-9._]{1,64}$/', (string)$filter_action)) {
    $where[]  = 'action = ?';
    $params[] = $filter_action;
}
if (is_string($filter_username) && strlen($filter_username) > 0) {
    $where[]  = 'username = ?';
    $params[] = substr((string)$filter_username, 0, 64);
}
if (is_numeric($filter_user_id)) {
    $where[]  = 'user_id = ?';
    $params[] = (int)$filter_user_id;
}
if (is_numeric($filter_days) && $filter_days > 0 && $filter_days <= 365) {
    $where[]  = 'ts >= DATE_SUB(NOW(), INTERVAL ? DAY)';
    $params[] = (int)$filter_days;
}
$where_sql = empty($where) ? '' : ('WHERE ' . implode(' AND ', $where));

// ── Fetch ───────────────────────────────────────────────────────────────
$sql = "SELECT audit_id, ts, user_id, username, ip_address, user_agent, action, "
     . "object_type, object_id, details "
     . "FROM audit_log {$where_sql} "
     . "ORDER BY audit_id DESC "
     . "LIMIT " . (int)$per_page . " OFFSET " . (int)$offset;

// DB::preparedQuery throws rather than returning false when the statement
// cannot be prepared, which is exactly what happens on a deployment that has
// not run cms/app/sql/upgrades/add_audit_log.sql yet. Catch it and say so,
// rather than letting an uncaught exception blank the page.
$result = false;
$query_error = '';
try {
    $result = DB::preparedQuery($sql, $params);
} catch (Exception $e) {
    $query_error = $e->getMessage();
} catch (Throwable $e) {
    $query_error = $e->getMessage();
}
if (!$result) {
    pl_log_error('system-audit query failed', strlen($query_error) ? $query_error : DB::error());
    $main_html['content'] = 'The audit log could not be read. If this system has '
                          . 'just been upgraded, apply '
                          . 'cms/app/sql/upgrades/add_audit_log.sql and reload '
                          . 'this page. The server log has the detail.';
    $default_template = new pikaTempLib('templates/default.html', $main_html);
    pika_exit($default_template->draw());
}

// Total count for pagination
$count_sql = "SELECT COUNT(*) AS n FROM audit_log {$where_sql}";
$total = 0;
try {
    $count_result = DB::preparedQuery($count_sql, $params);
    if ($count_result) {
        $row = DBResult::fetchRow($count_result);
        $total = isset($row['n']) ? (int)$row['n'] : 0;
    }
} catch (Exception $e) {
    pl_log_error('system-audit count query failed', $e->getMessage());
} catch (Throwable $e) {
    pl_log_error('system-audit count query failed', $e->getMessage());
}
$last_page = max(1, (int)ceil($total / $per_page));

// ── Build the HTML table ────────────────────────────────────────────────
$rows_html = '';
while ($r = DBResult::fetchRow($result)) {
    $ts        = pl_html_escape($r['ts']);
    $user_id   = $r['user_id'] !== null ? pl_html_escape($r['user_id']) : '—';
    $username  = $r['username'] !== null ? pl_html_escape($r['username']) : '—';
    $ip        = $r['ip_address'] !== null ? pl_html_escape($r['ip_address']) : '—';
    $action_td = pl_html_escape($r['action']);
    $obj       = '';
    if ($r['object_type'] !== null) {
        $obj = pl_html_escape($r['object_type']);
        if ($r['object_id'] !== null) {
            $obj .= ':' . pl_html_escape($r['object_id']);
        }
    } else {
        $obj = '—';
    }
    $details = '';
    if ($r['details'] !== null && strlen((string)$r['details']) > 0) {
        // Display as-is, escaped. Long payloads truncate with a tooltip-ish
        // full value in the title attribute (also escaped).
        $full = (string)$r['details'];
        $short = strlen($full) > 140 ? substr($full, 0, 137) . '…' : $full;
        $details = '<span title="' . pl_html_escape($full) . '">' . pl_html_escape($short) . '</span>';
    } else {
        $details = '—';
    }

    $rows_html .= "<tr>"
        . "<td><small>{$ts}</small></td>"
        . "<td>{$username} <small class=\"text-muted\">({$user_id})</small></td>"
        . "<td><code>{$action_td}</code></td>"
        . "<td>{$obj}</td>"
        . "<td><small>{$ip}</small></td>"
        . "<td>{$details}</td>"
        . "</tr>";
}

// Filter form state echoed back
$fa_val = is_string($filter_action)   ? pl_html_escape($filter_action)   : '';
$fu_val = is_string($filter_username) ? pl_html_escape($filter_username) : '';
$fd_val = is_numeric($filter_days)    ? (int)$filter_days                : '';
$fi_val = is_numeric($filter_user_id) ? (int)$filter_user_id             : '';

$content = '<form class="row g-2 mb-3" method="GET" action="' . pl_html_escape($base_url) . '/system-audit.php">'
    . '<div class="col-auto"><input class="form-control form-control-sm" type="text" name="action" placeholder="action (e.g. login.failure)" value="' . $fa_val . '"></div>'
    . '<div class="col-auto"><input class="form-control form-control-sm" type="text" name="username" placeholder="username" value="' . $fu_val . '"></div>'
    . '<div class="col-auto"><input class="form-control form-control-sm" type="number" name="user_id" placeholder="user_id" value="' . $fi_val . '"></div>'
    . '<div class="col-auto"><input class="form-control form-control-sm" type="number" name="days" placeholder="last N days" value="' . $fd_val . '" min="1" max="365"></div>'
    . '<div class="col-auto"><button class="btn btn-sm btn-primary" type="submit">Filter</button>'
    . ' <a class="btn btn-sm btn-link" href="' . pl_html_escape($base_url) . '/system-audit.php">Reset</a></div>'
    . '</form>';

$content .= '<p><small>' . (int)$total . ' matching event' . ($total == 1 ? '' : 's')
          . ', showing page ' . (int)$page . ' of ' . (int)$last_page . '.</small></p>';

$content .= '<table class="table table-sm table-striped table-hover">'
    . '<thead><tr>'
    . '<th>When</th><th>Actor</th><th>Action</th><th>Object</th><th>IP</th><th>Details</th>'
    . '</tr></thead><tbody>' . $rows_html . '</tbody></table>';

// Pagination (previous / next only — keeps the URL simple)
$qs_base = array();
if ($fa_val !== '') { $qs_base['action']   = $filter_action; }
if ($fu_val !== '') { $qs_base['username'] = $filter_username; }
if ($fd_val !== '') { $qs_base['days']     = $filter_days; }
if ($fi_val !== '') { $qs_base['user_id']  = $filter_user_id; }

function _audit_page_link($base_url, $qs_base, $label, $page_num)
{
    $qs = $qs_base;
    $qs['page'] = (int)$page_num;
    $url = pl_html_escape($base_url) . '/system-audit.php?' . http_build_query($qs);
    return '<a class="btn btn-sm btn-outline-secondary" href="' . $url . '">' . $label . '</a>';
}

$pagination = '<div class="d-flex gap-2">';
if ((int)$page > 1) {
    $pagination .= _audit_page_link($base_url, $qs_base, '« Previous', (int)$page - 1);
}
if ((int)$page < $last_page) {
    $pagination .= _audit_page_link($base_url, $qs_base, 'Next »', (int)$page + 1);
}
$pagination .= '</div>';
$content .= $pagination;

$main_html['content'] = $content;
$default_template = new pikaTempLib('templates/default.html', $main_html);
pika_exit($default_template->draw());
