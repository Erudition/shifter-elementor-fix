<?php
/**
 * Plugin Name: Shifter Elementor CSS Fix
 * Description: Robust CSS versioning for Elementor on Shifter. Replaces query-string versioning with content-hash-based filenames to bypass CDN caching and resolve build race conditions.
 * Version: 4.0
 * Author: Antigravity AI
 */

if ( ! defined( 'ABSPATH' ) ) exit;

/**
 * Add a debug signature to the HTML to verify the plugin is active in bakes.
 */
add_action( 'wp_head', function() {
    echo "\n<!-- Shifter Elementor CSS Fix v4.0 ACTIVE -->\n";
}, 1 );

/**
 * BREADCRUMB DIAGNOSTIC SYSTEM
 * Stores which code paths were taken for Each CSS template.
 */
global $shifter_css_breadcrumbs;
$shifter_css_breadcrumbs = [
    'pre-warmed' => [],
    'cache-hit'  => [],
    'lock-wrote' => [],
    'lock-skipped' => [],
    'lock-timeout' => [],
];

function shifter_css_breadcrumb($type, $id) {
    global $shifter_css_breadcrumbs;
    $shifter_css_breadcrumbs[$type][] = (int)$id;
}

/**
 * SECTION 1: PRE-WARM SHARED TEMPLATES
 * Ensure Kit and Library templates are warmed before page rendering begins.
 */
add_action('elementor/init', function() {
    if (!class_exists('\Elementor\Core\Files\CSS\Post')) return;

    $ids_to_warm = [];

    // 1. Target the active Kit
    $active_kit = get_option('elementor_active_kit');
    if ($active_kit) {
        $ids_to_warm[] = (int)$active_kit;
    }

    // 2. Target all Elementor Library documents (Templates, Headers, Footers)
    $library_ids = get_posts([
        'post_type' => 'elementor_library',
        'posts_per_page' => -1,
        'fields' => 'ids',
    ]);

    if (!empty($library_ids)) {
        $ids_to_warm = array_unique(array_merge($ids_to_warm, array_map('intval', $library_ids)));
    }

    // 3. Warm those we find missing
    foreach ($ids_to_warm as $id) {
        $meta = get_post_meta($id, '_elementor_css', true);
        
        if (empty($meta) || !is_array($meta) || empty($meta['status'])) {
            // Cold cache: Render synchronously
            try {
                $css_file = \Elementor\Core\Files\CSS\Post::create($id);
                $css_file->update();
                shifter_css_breadcrumb('pre-warmed', $id);
            } catch (\Throwable $e) {
                // Silently fail (catches both \Exception and PHP \Error)
                // Lock layer will still protect concurrent writes if this fails
            }
        } else {
            // Warm cache
            shifter_css_breadcrumb('cache-hit', $id);
        }
    }
}, 100);

/**
 * SECTION 3: BREADCRUMB OUTPUT
 */
add_action('wp_footer', function() {
    global $shifter_css_breadcrumbs;
    if (empty($shifter_css_breadcrumbs)) return;

    $summary = [];
    foreach ($shifter_css_breadcrumbs as $key => $ids) {
        $unique_ids = array_unique($ids);
        $summary[] = $key . '=' . (empty($unique_ids) ? '0' : implode(',', $unique_ids));
    }

    echo "\n<!-- shifter-css-fix-summary: " . esc_html(implode(' ', $summary)) . " -->\n";
}, 999);

/**
 * SECTION 2: ADVISORY LOCKING
 * Serialize concurrent writes to shared Elementor CSS meta using MySQL GET_LOCK.
 */
add_filter('update_post_metadata', 'shifter_lock_elementor_css_update', 10, 5);
add_filter('add_post_metadata',    'shifter_lock_elementor_css_update', 10, 5);

// 5th arg is $prev_value on update_post_metadata, $unique (bool) on add_post_metadata.
function shifter_lock_elementor_css_update($check, $object_id, $meta_key, $meta_value, $extra = null) {
    if ('_elementor_css' !== $meta_key) return $check;
    if (!is_array($meta_value) || empty($meta_value['status'])) return $check;

    global $wpdb;
    $lock_name = 'elementor_css_' . (int)$object_id;

    // Acquire MySQL Advisory Lock (10s timeout)
    $got_lock = $wpdb->get_var($wpdb->prepare("SELECT GET_LOCK(%s, 10)", $lock_name));

    if (!$got_lock) {
        shifter_css_breadcrumb('lock-timeout', $object_id);
        return $check; // Timeout/Fail: Fallback to unprotected behavior
    }

    // DOUBLE-CHECK: Did another worker complete while we waited?
    $raw = $wpdb->get_var($wpdb->prepare(
        "SELECT meta_value FROM {$wpdb->postmeta} WHERE post_id = %d AND meta_key = '_elementor_css' LIMIT 1",
        $object_id
    ));

    if ($raw) {
        $existing = maybe_unserialize($raw);
        if (is_array($existing) && !empty($existing['status'])) {
            // Success! Another worker already wrote it.
            $wpdb->get_var($wpdb->prepare("SELECT RELEASE_LOCK(%s)", $lock_name));
            shifter_css_breadcrumb('lock-skipped', $object_id);
            return true; // Skip this write
        }
    }

    /**
     * WE ARE THE WINNER: Release the lock strictly AFTER the write completes.
     * We use a one-time hook on the success actions.
     */
    $release_callback = function($meta_id, $obj_id, $key) use ($lock_name, $object_id, &$release_callback) {
        if ($obj_id == $object_id && $key === '_elementor_css') {
            global $wpdb;
            $wpdb->get_var($wpdb->prepare("SELECT RELEASE_LOCK(%s)", $lock_name));
            remove_action('updated_postmeta', $release_callback);
            remove_action('added_post_meta', $release_callback);
        }
    };

    add_action('updated_postmeta', $release_callback, 10, 3);
    add_action('added_post_meta',   $release_callback, 10, 3);

    shifter_css_breadcrumb('lock-wrote', $object_id);
    return $check; // $check is null — returning null lets WordPress proceed with the write
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
        $max_retries = 50;
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
     * Fallback to global Elementor version if the query parameter is missing.
     */
    $ver = '';
    if (isset($url['query'])) {
        parse_str($url['query'], $query_params);
        if (isset($query_params['ver'])) {
            $ver = '.v' . preg_replace('/[^a-zA-Z0-9_\.-]/', '', (string)$query_params['ver']);
        }
    }
    
    if (empty($ver) && defined('ELEMENTOR_VERSION')) {
        $ver = '.v' . ELEMENTOR_VERSION;
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



