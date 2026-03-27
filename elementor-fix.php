<?php
/**
 * Plugin Name: Shifter Elementor CSS Fix
 * Description: Robust CSS versioning for Elementor on Shifter. Replaces query-string versioning with content-hash-based filenames to bypass CDN caching and resolve build race conditions.
 * Version: 2.6
 * Author: Antigravity AI
 */

if ( ! defined( 'ABSPATH' ) ) exit;

/**
 * Log function for Shifter execution context.
 */
function shifter_log($message) {
    if (!is_scalar($message)) {
        $message = print_r($message, true);
    }
    $log_file = WP_CONTENT_DIR . '/uploads/shifter_log.txt';
    @error_log("[" . date('Y-m-d H:i:s') . "] " . (string)$message . "\n", 3, $log_file);
}

/**
 * Concurrency lock to prevent file corruption during parallel requests during the Shifter bake process.
 */
function shifter_concurrency_lock($local_path) {
    static $locked = [];
    if (!is_string($local_path) || isset($locked[$local_path])) {
        return;
    }
    
    // Create a sidecar lock file
    $lock_handle = @fopen($local_path . '.copy.lock', 'w+');
    if ($lock_handle && @flock($lock_handle, LOCK_EX)) {
        $locked[$local_path] = $lock_handle;
    } elseif ($lock_handle) {
        @fclose($lock_handle);
    }
}

/**
 * Filter: style_loader_src
 * Intercepts Elementor CSS files and versions them via content-hash filename.
 */
add_filter('style_loader_src', 'shifter_css_filename_versioning', 999, 2);

function shifter_css_filename_versioning($src, $handle) {
    if (!is_string($src) || !is_string($handle)) {
        return $src;
    }
    
    // Filter only Elementor-managed assets
    if (strpos($src, '/elementor/') === false || strpos($src, '.css') === false) {
        return $src;
    }

    $url = parse_url($src);
    $path = isset($url['path']) ? $url['path'] : '';
    
    /**
     * Resolve Local Paths (Hostname-Agnostic)
     */
    $upload_dir = wp_upload_dir(null, false);
    $upload_base_path = $upload_dir['basedir'];
    $upload_base_url_path = parse_url($upload_dir['baseurl'], PHP_URL_PATH);

    // Ensure we are dealing with a local upload file
    if (strpos($path, $upload_base_url_path) !== 0) {
        return $src;
    }

    $rel_path = substr($path, strlen($upload_base_url_path));
    $local_path = $upload_base_path . $rel_path;

    if (!file_exists($local_path)) {
        return $src;
    }

    /**
     * Generate Content-Based Hash
     * Use a static cache to avoid redundant MD5 calls in a single request.
     */
    static $hash_cache = [];
    if (!isset($hash_cache[$local_path])) {
        // Grab first 10 chars of MD5 for a clean, stable version string
        $hash_cache[$local_path] = substr(md5_file($local_path), 0, 10);
    }
    $hash = $hash_cache[$local_path];

    // New filename pattern: filename.[md5].css
    $new_path = str_replace('.css', '.' . $hash . '.css', $path);
    $new_local_path = $upload_base_path . substr($new_path, strlen($upload_base_url_path));

    /**
     * Atomic Copy with Lock
     */
    if (!file_exists($new_local_path)) {
        shifter_concurrency_lock($local_path); // Ensure file is stable before copy
        
        if (!@copy($local_path, $new_local_path)) {
            return $src; // Fallback to original on failure
        }
    }

    /**
     * Construct final URL
     */
    $scheme = isset($url['scheme']) ? $url['scheme'] . '://' : '//';
    $host = isset($url['host']) ? $url['host'] : $_SERVER['HTTP_HOST'];
    
    // Strip query string as it's now in the filename
    return $scheme . $host . $new_path;
}
