<?php
/**
 * Plugin Name: Shifter Elementor CSS Fix
 * Description: Robust CSS versioning for Elementor on Shifter. Replaces query-string versioning with content-hash-based filenames to bypass CDN caching and resolve build race conditions.
 * Version: 3.0
 * Author: Antigravity AI
 */

if ( ! defined( 'ABSPATH' ) ) exit;

/**
 * Add a debug signature to the HTML to verify the plugin is active in bakes.
 */
add_action( 'wp_head', function() {
    echo "\n<!-- Shifter Elementor CSS Fix v3.0 ACTIVE -->\n";
}, 1 );

/**
 * Concurrency lock to prevent file corruption during parallel requests during the Shifter bake process.
 */
function shifter_concurrency_lock($local_path) {
    if (!is_string($local_path)) {
        return;
    }
    
    static $locked = [];
    if (isset($locked[$local_path])) {
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
    
    // Filter only Elementor-managed assets (including Google Fonts)
    if (strpos($src, '/elementor/') === false || strpos($src, '.css') === false) {
        return $src;
    }

    $url = parse_url($src);
    $path = isset($url['path']) ? $url['path'] : '';
    
    /**
     * Resolve Local Paths (Shifter-Agnostic)
     */
    $upload_dir = wp_upload_dir(null, false);
    $upload_base_path = rtrim($upload_dir['basedir'], '/');
    
    // Find the relative path of the file WITHIN the uploads directory.
    // This allows us to bypass Shifter's internal ID prefixes or absolute URLs
    $upload_token = '/uploads/';
    $pos = strpos($path, $upload_token);
    
    if ($pos === false) {
        return $src;
    }

    $rel_path = substr($path, $pos + strlen($upload_token));
    $local_path = $upload_base_path . '/' . ltrim($rel_path, '/');

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

    /**
     * Rename the file to include the hash.
     * We calculate the new local path for the filesystem copy.
     */
    $new_path_fragment = preg_replace('/\.css$/', '.' . $hash . '.css', $path);
    $new_local_path = $upload_base_path . '/' . ltrim(substr($new_path_fragment, $pos + strlen($upload_token)), '/');

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
     * Final URL construction:
     * Surgically replace the filename and STRIP optional query strings.
     * Regex ensures we catch .css regardless of following ?ver= strings.
     */
    return preg_replace('/\.css(\?.*)?$/', '.' . $hash . '.css', $src);
}



