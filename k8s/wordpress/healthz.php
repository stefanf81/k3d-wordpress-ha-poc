<?php
header('Content-Type: text/plain');

$host = getenv('WORDPRESS_DB_HOST') ?: 'mariadb:3306';
$port = 3306;

if (strpos($host, ':') !== false) {
    [$host, $port] = explode(':', $host, 2);
    $port = (int) $port;
}

mysqli_report(MYSQLI_REPORT_OFF);

$db = @new mysqli(
    $host,
    getenv('WORDPRESS_DB_USER'),
    getenv('WORDPRESS_DB_PASSWORD'),
    getenv('WORDPRESS_DB_NAME'),
    $port
);

if ($db->connect_errno) {
    http_response_code(503);
    echo "database unavailable\n";
    exit;
}

$result = @$db->query("SELECT 1 FROM wp_options LIMIT 1");

if (!$result) {
    http_response_code(503);
    echo "wordpress schema unavailable\n";
    exit;
}

http_response_code(200);
echo "ok\n";
