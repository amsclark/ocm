<?php

chdir('..');

define('PL_DISABLE_SECURITY',true);

include('pika-danio.php');
pika_init();
require_once('pikaAuth.php');
require_once('pikaSettings.php');

pikaAuth::getInstance()->logout();


$settings = pikaSettings::getInstance();

// Ensure base_url is absolute
$base_url = $settings['base_url'];
if (!preg_match('/^http(s)?:\/\//', $base_url)) {
    // If base_url is relative, construct the absolute URL
    $base_url = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? "https" : "http") . "://{$_SERVER['HTTP_HOST']}/" . ltrim($base_url, '/');
}

// Clear output buffer to ensure no output before headers
if (ob_get_length()) {
    ob_clean();
}


// Add cache-control headers to prevent caching
header("Cache-Control: no-cache, must-revalidate"); // HTTP/1.1
header("Expires: Sat, 26 Jul 1997 05:00:00 GMT"); // Date in the past

header("Location: " . $base_url);
exit();
