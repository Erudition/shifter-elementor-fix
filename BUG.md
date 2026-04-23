# Upstream Bug: Elementor CSS Cache Race Condition Under Parallel Crawling

## Overview

Elementor's CSS caching mechanism is not concurrency-safe. When multiple PHP
workers render pages that share a common template (e.g., a Single Post Template),
they can corrupt each other's cached CSS by writing to the same `wp_postmeta` row
simultaneously. This produces nondeterministic layout failures during parallel
site crawls such as the Shifter Bake.

**This bug is independent of our `elementor-fix.php` plugin.** It was reproduced
with the plugin disabled, Elementor freshly updated, object cache cleared,
Elementor CSS reset, and the CSS Print Method set to "Internal Embedding."

## Diagnostic Evidence

Artifact `e47bc55e` — two blog posts from the **same bake**, sharing the same
Single Post Template (Elementor Document ID 4634):

| Page | `elementor-frontend-inline-css` size | `.elementor-4634` selectors |
|---|---|---|
| Monique Leija (healthy) | 142,129 bytes | **Present** |
| Elevate IT Career (broken) | 95,984 bytes | **Absent** |

Both pages reference `data-elementor-id="4634"` in their HTML body. The broken
page's DOM expects the template styles, but they were never injected. The 46KB
deficit accounts for the entire `.elementor-4634` selector block.

## Root Cause

### The Trigger: Empty Cache + Parallel Crawl

The reproduction sequence was:

1. **Elementor CSS Reset** — deletes all `_elementor_css` post meta rows.
2. **Staging verification** — a single user browses the site sequentially,
   triggering CSS generation one template at a time. Everything looks correct.
3. **Bake** — Shifter's parallel crawler hits dozens of blog posts
   simultaneously. Every post shares Template 4634.

### The Race

In `Elementor\Core\Files\CSS\Base::enqueue()` (line 228):

```php
if ( '' === $meta['status'] || $this->is_update_required() ) {
    $this->update();
    $meta = $this->get_meta();
}
```

After the CSS Reset, every template's `_elementor_css` meta has `status === ''`.
The first parallel wave of the crawler triggers this sequence:

1. **Worker A** (rendering Post X) creates `Post_CSS(4634)`, calls `enqueue()`,
   finds `status === ''`, enters `update()`.
2. **Worker B** (rendering Post Y) creates `Post_CSS(4634)`, calls `enqueue()`,
   **also** finds `status === ''`, enters `update()`.
3. Both workers independently parse the template's element tree and generate CSS.
4. **Worker A** completes, calls `update_post_meta(4634, '_elementor_css', $meta)`
   with the full 142KB result.
5. **Worker B** completes (possibly with a different/truncated result due to
   timing or resource pressure) and calls `update_post_meta()` on the **same
   row**, overwriting Worker A's result.
6. **Worker C** (rendering Post Z) reads the corrupted/truncated meta and prints
   it. The page is now missing 46KB of template styles.

### Why There Is No Protection

- **No locking**: There are no transients, advisory locks, or mutex mechanisms
  anywhere in `Elementor\Core\Files\CSS\`. The `update_post_meta()` call on
  `post.php:129` is a bare, unprotected database write.
- **No double-check**: After acquiring the "right to update," the worker does not
  re-read the meta to see if another worker already completed the render.
- **Static `$printed` guard is per-process only**: The `self::$printed` array in
  `Base::enqueue()` prevents double-enqueuing within a single PHP request, but
  offers zero protection across parallel workers.

### Additional Factor: Dynamic Tags

Templates using Dynamic Tags (e.g., `{Post Title}`, `{Post Content}`) trigger
`Dynamic_CSS`, which extends `Post_Local_Cache`. This class hardcodes
`is_update_required()` to return `true` and uses in-memory-only caching
(`$this->meta_cache`). While `Dynamic_CSS` itself doesn't write to the database,
it depends on the parent `Post_CSS` for the template being stable — which it
isn't under concurrency.

## Environment Notes

- **Staging and Bake share the same infrastructure**: same MySQL database (cloned
  at bake start), same S3 backend via the `s3-uploads` plugin, same filesystem
  paths. There is no URL mismatch or environment difference that triggers the
  re-render — the empty `status` field alone is sufficient.
- **`flock()` is unavailable**: The S3 stream wrapper silently ignores POSIX file
  locks. This is why our plugin's earlier `flock()`-based approach failed.
- **`GET_LOCK()` is viable**: MySQL advisory locks (`GET_LOCK`/`RELEASE_LOCK`)
  operate at the database level and are unaffected by the S3 stream wrapper.

## Affected Code Paths

| File | Line | Role |
|---|---|---|
| `core/files/css/base.php` | 228 | Decision to re-render (empty status check) |
| `core/files/css/base.php` | 132-158 | `update()` — renders CSS and writes meta |
| `core/files/css/post.php` | 129 | `update_meta()` — bare `update_post_meta()` |
| `core/files/css/post.php` | 114-116 | `load_meta()` — bare `get_post_meta()` |
| `core/files/css/post-local-cache.php` | 22-24 | `is_update_required()` — hardcoded `true` |

## Proposed Fix: MySQL Advisory Locking

Intercept `Post_CSS::update_meta()` to wrap the render-and-write cycle in a
`GET_LOCK()` / `RELEASE_LOCK()` pair keyed on the post ID. After acquiring the
lock, re-read the meta — if another worker already completed the render, skip the
redundant write. This transforms the parallel race into a serialized queue for
shared templates while leaving per-post CSS (which has no contention) unaffected.
