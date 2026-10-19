<?php
define('DB_NAME', getenv('WORDPRESS_DB_NAME'));
define('DB_USER', getenv('WORDPRESS_DB_USER'));
define('DB_PASSWORD', getenv('WORDPRESS_DB_PASSWORD'));
define('DB_HOST', getenv('WORDPRESS_DB_HOST'));
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

// All web replicas must share the same auth keys. Values come from the
// wordpress-keys Secret rather than being committed in this ConfigMap.
define('AUTH_KEY',         getenv('WORDPRESS_AUTH_KEY'));
define('SECURE_AUTH_KEY',  getenv('WORDPRESS_SECURE_AUTH_KEY'));
define('LOGGED_IN_KEY',    getenv('WORDPRESS_LOGGED_IN_KEY'));
define('NONCE_KEY',        getenv('WORDPRESS_NONCE_KEY'));
define('AUTH_SALT',        getenv('WORDPRESS_AUTH_SALT'));
define('SECURE_AUTH_SALT', getenv('WORDPRESS_SECURE_AUTH_SALT'));
define('LOGGED_IN_SALT',   getenv('WORDPRESS_LOGGED_IN_SALT'));
define('NONCE_SALT',       getenv('WORDPRESS_NONCE_SALT'));

$table_prefix = 'wp_';

define('WP_ENVIRONMENT_TYPE', 'local');
define('WP_DEBUG', true);
// Keep the debug file outside the web root in this local lab.
define('WP_DEBUG_LOG', '/tmp/wp-debug.log');
define('WP_DEBUG_DISPLAY', false);

define('WP_MEMORY_LIMIT', '128M');
define('WP_MAX_MEMORY_LIMIT', '256M');

// Reduce browser/admin code-execution paths. Plugins remain managed by
// the explicit WP-CLI bootstrap Job.
define('DISALLOW_FILE_EDIT', true);

// One central WP-CLI Job owns core/plugin reconciliation. Prevent three
// web replicas from independently performing background updates.
define('WP_AUTO_UPDATE_CORE', false);
define('AUTOMATIC_UPDATER_DISABLED', true);

// Multiple web replicas can otherwise all trigger wp-cron.
// The wordpress-cron Kubernetes CronJob triggers it centrally.
define('DISABLE_WP_CRON', true);

if (
    isset($_SERVER['HTTP_X_FORWARDED_PROTO']) &&
    strpos($_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false
) {
    $_SERVER['HTTPS'] = 'on';
}

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}

require_once ABSPATH . 'wp-settings.php';
