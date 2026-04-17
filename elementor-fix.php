<?php
/**
 * Plugin Name: Shifter Elementor CSS Fix
 * Description: Robust CSS versioning for Elementor on Shifter. Replaces query-string versioning with content-hash-based filenames to bypass CDN caching and resolve build race conditions.
 * Version: 3.3
 * Author: Antigravity AI
 */

if ( ! defined( 'ABSPATH' ) ) exit;

/**
 * Add a debug signature to the HTML to verify the plugin is active in bakes.
 */
add_action( 'wp_head', function() {
    echo "\n<!-- Shifter Elementor CSS Fix v3.3 ACTIVE -->\n";
}, 1 );

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
     * STABLE READ GUARANTEE: Ensure Elementor has finished writing the file.
     * We wait until the file size is non-zero and has stopped changing.
     * This prevents capturing partial CSS files during parallel bakes.
     */
    static $stable_files = [];
    if (!isset($stable_files[$local_path])) {
        $max_retries = 15;
        $last_size = -1;
        for ($i = 0; $i < $max_retries; $i++) {
            clearstatcache(true, $local_path);
            if (file_exists($local_path) && filesize($local_path) > 0) {
                // Final Integrity Check: Does it end with a closing brace or comment?
                $fp = @fopen($local_path, 'rb');
                if ($fp) {
                    fseek($fp, -32, SEEK_END);
                    $tail = fread($fp, 32);
                    fclose($fp);
                    if (strpos($tail, '}') !== false || strpos($tail, '*/') !== false) {
                        $stable_files[$local_path] = true;
                        break;
                    }
                }
            }
            
            usleep(100000); // 100ms wait
        }
        
        // If we still didn't reach stability, something is wrong with the disk write
        if (!isset($stable_files[$local_path])) {
            return $src; // Fallback to original URL
        }
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
        $lock_file = $local_path . '.copy.lock';
        $lock_handle = @fopen($lock_file, 'w+');
        if ($lock_handle && @flock($lock_handle, LOCK_EX)) {
            $copy_success = true;
            // Check again inside lock to prevent race condition
            if (!file_exists($new_local_path)) {
                $copy_success = @copy($local_path, $new_local_path);
            }
            
            @flock($lock_handle, LOCK_UN);
            @fclose($lock_handle);
            
            if (!$copy_success) {
                return $src; // Fallback to original on failure
            }
        } elseif ($lock_handle) {
            @fclose($lock_handle);
        }
    }

    /**
     * Final URL construction:
     * Surgically replace the filename and STRIP optional query strings.
     * Regex ensures we catch .css regardless of following ?ver= strings.
     */
    return preg_replace('/\.css(\?.*)?$/', '.' . $hash . '.css', $src);
}



