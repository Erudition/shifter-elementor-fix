<?php
/**
 * Plugin Name: Shifter Elementor CSS Fix
 * Description: Robust CSS versioning for Elementor on Shifter. Replaces query-string versioning with filename-based versioning to bypass CDN caching issues.
 * Version: 2.4
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
    
    // Directory level lock since Elementor writes multiple files
    $lock_handle = @fopen($local_path . '.copy.lock', 'w+');
    if ($lock_handle && @flock($lock_handle, LOCK_EX)) {
        $locked[$local_path] = $lock_handle;
    } elseif ($lock_handle) {
        @fclose($lock_handle);
    }
}

/**
 * Filter: style_loader_src
 * Intercepts Elementor CSS files and versions them via filename.
 */
add_filter('style_loader_src', 'shifter_css_filename_versioning', 999, 2);

function shifter_css_filename_versioning($src, $handle) {
    if (!is_string($src) || !is_string($handle)) {
        return $src;
    }
    
    // Filter only Elementor CSS files
    if (strpos($src, 'elementor/css/') === false) {
        return $src;
    }

    $url = parse_url($src);
    if (!isset($url['query'])) {
        return $src;
    }
    
    parse_str($url['query'], $q);
    if (!isset($q['ver'])) {
        return $src;
    }

    $ver = $q['ver'];
    $path = $url['path'];
    if (strpos($path, '.css') === false) {
        return $src;
    }

    // New filename-based versioning pattern: filename.[timestamp].css
    $new_path = str_replace('.css', '.' . $ver . '.css', $path);

    /**
     * Resolve Local Paths (Hostname-Agnostic)
     */
    $upload_dir = wp_upload_dir(null, false);
    $upload_base_path = $upload_dir['basedir'];
    $upload_base_url_path = parse_url($upload_dir['baseurl'], PHP_URL_PATH);

    // Ensure we are only dealing with upload files
    if (strpos($path, $upload_base_url_path) !== 0) {
        return $src;
    }

    $rel_path = substr($path, strlen($upload_base_url_path));
    $local_path = $upload_base_path . $rel_path;
    $new_local_path = $upload_base_path . substr($new_path, strlen($upload_base_url_path));

    /**
     * Create the versioned file if it doesn't exist
     */
    if (file_exists($local_path)) {
        shifter_concurrency_lock($local_path); // Lock during creation
        
        if (!file_exists($new_local_path)) {
            if (!@copy($local_path, $new_local_path)) {
                // Return original src if copy fails to avoid 404
                return $src;
            }
        }
    } else {
        // Source file not found on disk, return original to avoid path corruption
        return $src;
    }

    /**
     * Construct final URL
     */
    $scheme = isset($url['scheme']) ? $url['scheme'] . '://' : '//';
    $host = isset($url['host']) ? $url['host'] : $_SERVER['HTTP_HOST'];
    return $scheme . $host . $new_path;
}
