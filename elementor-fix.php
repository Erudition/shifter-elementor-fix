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
    // Strip query strings and fragments from the physical path
    $rel_path = preg_replace('/(\?|#).*$/', '', $rel_path);
    $local_path = $upload_base_path . '/' . ltrim($rel_path, '/');

    if (!file_exists($local_path)) {
        return $src;
    }

    /**
     * STABLE READ GUARANTEE: Ensure Elementor has finished writing the file.
     * We wait until the file is structurally complete and contains no placeholders.
     */
    static $stable_files = [];
    if (!isset($stable_files[$local_path])) {
        $max_retries = 15;
        for ($i = 0; $i < $max_retries; $i++) {
            clearstatcache(true, $local_path);
            if (file_exists($local_path) && filesize($local_path) > 0) {
                $content = @file_get_contents($local_path);
                if ($content) {
                    // Integrity Check: Balanced Braces + No Placeholders
                    $braces_open = substr_count($content, '{');
                    $braces_close = substr_count($content, '}');
                    
                    if ($braces_open > 0 && $braces_open === $braces_close && strpos($content, '{{WRAPPER}}') === false) {
                        $stable_files[$local_path] = true;
                        break;
                    }
                }
            }
            usleep(100000); // 100ms wait
        }
        
        // If still unstable, return a URL that the audit tool will flag as a failure.
        if (!isset($stable_files[$local_path])) {
            return preg_replace('/\.css(\?.*)?$/', '.unstable-content.css', $src);
        }
    }

    /**
     * Generate Content-Based Hash
     */
    static $hash_cache = [];
    if (!isset($hash_cache[$local_path])) {
        $hash_cache[$local_path] = substr(md5_file($local_path), 0, 10);
    }
    $hash = $hash_cache[$local_path];

    /**
     * Version Migration: Extract existing ?ver= and inject into filename.
     */
    $ver = '';
    if (isset($url['query'])) {
        parse_str($url['query'], $query_params);
        if (isset($query_params['ver'])) {
            $ver = '.v' . preg_replace('/[^a-zA-Z0-9_\.-]/', '', (string)$query_params['ver']);
        }
    }

    /**
     * Determine New Path
     */
    $new_path_fragment = preg_replace('/\.css$/', $ver . '.' . $hash . '.css', $path);
    $new_local_path = $upload_base_path . '/' . ltrim(substr($new_path_fragment, $pos + strlen($upload_token)), '/');
    $new_local_path = preg_replace('/(\?|#).*$/', '', $new_local_path);

    /**
     * S3-Native Atomic Creation
     * Use 'x' mode to ensure only one worker performs the copy.
     */
    if (!file_exists($new_local_path)) {
        // Attempt to create the file exclusively
        $handle = @fopen($new_local_path, 'x');
        if ($handle) {
            // We are the winner! Perform the copy.
            if (@copy($local_path, $new_local_path)) {
                @fclose($handle);
            } else {
                @fclose($handle);
                @unlink($new_local_path); // Cleanup on failure
                return preg_replace('/\.css(\?.*)?$/', '.copy-failed.css', $src);
            }
        } else {
            // If fopen failed, another worker is already handling it or it already exists.
            // We MUST wait for it to be physically available on S3 before returning the URL.
            $wait_retries = 10;
            for ($j = 0; $j < $wait_retries; $j++) {
                clearstatcache(true, $new_local_path);
                if (file_exists($new_local_path)) {
                    break;
                }
                usleep(200000); // 200ms wait
            }
        }
    }

    /**
     * Return the versioned URL. No fallback allowed.
     */
    return preg_replace('/\.css(\?.*)?$/', $ver . '.' . $hash . '.css', $src);
}



