# Technical Lessons: Elementor CSS Versioning on Shifter

This document records the architectural pitfalls and solutions discovered while implementing MD5 content-hash versioning for Elementor on the Shifter static platform.

## 1. The Hex-ID URL Mismatch (Critical)
*   **The Issue**: Shifter's staging environments (the live WordPress container) use internal 40-character hexadecimal IDs in URLs (e.g., `/b306415ec.../uploads/`).
*   **The Pitfall**: These IDs are **stripped** during the static artifact generation process. 
*   **The Failure**: In `v2.8`, we attempted to use root-relative paths that accidentally included these IDs in the HTML. This resulted in the browser looking for `/b306.../` on the static preview domain, where it didn't exist, leading to 403/404 errors.
*   **The Rule**: Never hardcode or "guess" the root path. Always work relative to the `/uploads/` token or use surgical string replacement.

## 2. Crawler Asset Discovery & CDNs
*   **The Issue**: Shifter's "Bake" process involves a crawler that transforms WordPress pages into static HTML.
*   **The Pitfall**: If an asset URL points to a full absolute hostname (like `cdn.getshifter.co`), the crawler may treat it as an "external" resource and fail to include the physical file in the static artifact.
*   **The Result**: The site looks correct while the CDN has the file, but if the CDN cache is purged or a new site is built, the styles vanish because they aren't actually in the build.
*   **The Rule**: Ensure the crawler sees a path it recognizes as local to the container during the build phase.

## 3. Surgical URL Modification
*   **The Lesson**: The most stable way to version assets on Shifter is to perform a `preg_replace` on the **original URL string** provided by WordPress.
*   **Why**: This preserves the platform's intended scheme, hostname, and hexadecimal IDs exactly as they were delivered to the browser filter, avoiding "fancy" reconstruction bugs.

## 4. Regex & Query Strings (`?ver=`)
*   **The Issue**: WordPress/Elementor often appends version query strings to CSS files (e.g., `style.css?ver=1.2.3`).
*   **The Failure**: A simple regex like `/\.css$/` will fail to match these URLs because they don't end in `.css`.
*   **The Solution**: Use a regex that accounts for (and removes) optional query strings: `/\.css(\?.*)?$/`. This ensures the content-hash is correctly injected and the redundant `?ver=` string is stripped.

## 5. Shifter Root Cache Stalling
*   **The Issue**: In multiple bakes (`1e99`, `93c9ef`), the home page (`index.html`) remained "stuck" on an old version of Elementor (3.35.5) while subpages were correctly updated (3.35.8).
*   **The Lesson**: Shifter's internal generator can cache the root page more aggressively than subpages. 
*   **Recovery**: A slug change or a deeper cache invalidation within the Shifter dashboard may be required if the home page fails to update after a plugin change.

## 6. Concurrency & File Locking
*   **The Issue**: Shifter generates pages in parallel. Multiple PHP processes may try to generate or copy the same shared CSS file at the exact same millisecond.
*   **The Result**: Build-time deadlocks and "partially written" (corrupted) CSS files.
*   **The Solution**: Implement `flock()` on sidecar `.lock` files. This ensures only one process writes the hashed file at a time, protecting file integrity and reducing 15+ minute build times down to seconds.

## 7. The Performance Lab (Meta-Plugin) Conflict (Definitive)
*   **The Issue**: The **Performance Lab (v4.1.0+)** meta-plugin performs a global optimization (likely its "Asset Manager" or a hidden pre-processing filter) that strips Elementor conditional assets (e.g., `shapes.min.css`) during both live renders and static bakes.
*   **The Symptom**: Shape dividers lose their `position: absolute` and render inline, while loop grids lose their basic common-layout styles.
*   **The Evidence**: Deactivating the meta-plugin **instantly** restores these styles site-wide without requiring metadata regeneration or "Priming."
*   **The Rule**: Keep the Performance Lab meta-plugin DEACTIVATED on Shifter. Its presence is incompatible with how Elementor and Shifter interact.

*   **The Rule**: The versioning plugin should ONLY touch files in `/wp-content/uploads/elementor/`. Modifying core plugin CSS is unnecessary and risks breaking Elementor's native dependency tree.

## 10. Artifact Sitemap Blocking (Security/SEO)
*   **The Issue**: Shifter's **Preview** domain (`.preview.getshifter.io`) often returns **403 Forbidden** or **404** when trying to access `.xml` sitemaps directly, even if they are bundled in the artifact.
*   **The Reason**: This is likely a security/SEO measure to prevent search engines from crawling and indexing unpublished static snapshots.
*   **The Solution**: When auditing a **Preview Artifact**, use the `--sitemap-from` flag in the `test-artifact.sh` tool to fetch the site structure from the **Live Site** (or **Staging**) and rewrite the URLs to the artifact's domain.

## 11. Provisional Previews & 403 Forbidden
*   **The Issue**: A Shifter artifact being in the `ready` state does not mean its static preview environment is active. 
*   **The Symptom**: Attempting to audit or view the `.preview.getshifter.io` URL immediately after a bake often results in a **403 Forbidden** error.
*   **The Lesson**: The preview environment is created on-demand. To make it accessible to the audit script, it must be "Launch"ed—typically by clicking the 'Preview' button in the Shifter Dashboard.
*   **The Rule**: If the audit tool reports a 403, verify that the artifact has been provisioned in the dashboard.

## 12. Mandatory Trailing Slashes
*   **The Issue**: Shifter's static architecture (folders containing `index.html`) relies on the trailing slash for correct CloudFront resolution.
*   **The Symptom**: Accessing a directory path without a trailing slash (e.g., `/course/awr-136`) often results in a **403 Forbidden** (LambdaGeneratedResponse) from CloudFront, or an incorrect redirect to an internal staging URL.
*   **The Rule**: Always append a trailing slash to all internal URLs. The audit tool is now configured to enforce this on all discovered slugs.
## 13. Preview Asset Referer Protection (CloudFront)
*   **The Issue**: Shifter's `.preview.getshifter.io` domain uses a CloudFront distribution that enforces "Hotlink Protection" or "Same-Origin" policies for static assets (`.css`, `.js`, `.png`, etc.).
*   **The Symptom**: `curl` requests for assets return **403 Forbidden** (LambdaGeneratedResponse), while the same assets load correctly in a browser. HTML pages (`text/html`) are usually exempt.
*   **The Solution**: All `curl` requests for assets on the preview domain **MUST** include a `Referer` header matching the base preview URL (e.g., `-H "Referer: https://[AID].preview.getshifter.io/"`).
*   **The Rule**: Never attempt to audit or scrape Shifter preview assets with `curl` without the local `Referer` header.
## 14. High-Fidelity Structural Regression Engine
*   **The Issue**: Elementor randomizes certain IDs (e.g., `e-loop-item-XXXX`) and `post-XXXX` id attributes on every render.
*   **The Pitfall**: Simple text-based diffing or bitwise comparison triggers regression alerts for every render, even if the layout is identical. This makes automated auditing noisy and unreliable.
*   **The Solution**: Move beyond flat-file diffing to **Structural Tree Comparison**:
    1.  **Normalization (`tidy`)**: Convert fragmented HTML into valid, standardized XHTML5.
    2.  **Structural Masking (`sed`)**: Replace randomized numeric IDs with a generic `ID-MASKED` token before the comparison phase.
    3.  **Hhigh-Fidelity Diff (`xmldiff`)**: Perform a tree-based comparison that ignores "move" operations (reordering of identical nodes) while flagging actual node name, attribute, or text content changes.
*   **The Result**: The engine now correctly prunes identical pages even if IDs have shifted, providing high-confidence regression signatures.

## 15. PHP Worker Exhaustion & Thread Latency
*   **The Issue**: Adding manual `usleep()` delays or mandatory filesystem wait loops inside frequently fired filters (like `style_loader_src`) artificially inflates the lifecycle of the PHP request.
*   **The Pitfall**: Because Shifter generates sites massively in parallel (the crawler hits 10-20 pages at once), those minor 100ms artificial delays stack exponentially and immediately exhaust the small PHP-FPM child pool inside the container.
*   **The Result**: Bizarre, non-deterministic HTTP rendering behavior where elements of the HTML `<head>` (like essential Elementor `<link>` tags) are arbitrarily dropped due to underlying request timeouts or process thread shedding before the function concludes. 
*   **The Rule**: Custom build-step interceptors must execute as close to 0ms as possible. If file verification loops are strictly necessary, test preconditions (like file-end integrity) *before* invoking `sleep()`.

## 17. S3-Native Atomicity vs. `flock()`
*   **The Issue**: Traditional PHP `flock()` relies on the underlying filesystem supporting advisory locks.
*   **The Pitfall**: Shifter's S3 stream wrapper (s3-uploads) **silently ignores** `flock()`, returning `true` without actually locking the file. This leads to hidden race conditions during parallel bakes.
*   **The Solution**: Use **`fopen(..., 'x')`** (Exclusive Create). On S3, this utilizes the "Put if not exists" protocol. Only the first worker to initiate the write will succeed; all others will fail immediately.
*   **The Rule**: Never use `flock()` on S3. Use atomic creation modes (`x`) to manage distributed concurrency.

## 18. Database-Backed Hash Registry
*   **The Issue**: In a parallel bake, hundreds of workers may hit pages sharing the same CSS file (e.g., `global.css`). 
*   **The Pitfall**: If every worker performs its own `md5_file()` and `copy()` operation, the redundant S3 traffic and CPU load can crash the bake or trigger CloudFront rate limits.
*   **The Solution**: Use the WordPress database (the `shifter_css_hashes` option) as a central registry.
*   **The Logic**: The first worker to version a file saves the mapping to the database. All subsequent workers perform a lightweight `get_option()` check and return the hashed URL instantly without ever touching the S3 filesystem.

## 19. The "Fallback" Masking Trap
*   **The Issue**: If a plugin fails to version a file (e.g., due to a timeout) and "falls back" to the original unversioned URL, the page may appear to load correctly.
*   **The Pitfall**: Because the unversioned file still exists on S3, the audit tool sees a **200 OK** and passes the page. However, that file might be **stale content** from months ago, cached for a year by CloudFront.
*   **The Solution**: **Strict Audit Enforcement**. The audit tool now uses regex to ensure EVERY Elementor CSS link contains a signature 10-char hash. Any URL without a hash is treated as a critical failure, even if it returns 200.
*   **The Rule**: Fallbacks are bugs. If you can't version it, fail the audit so it can be fixed.

## 20. The "Source of Truth" Persistence
*   **The Issue**: It is tempting to `rename()` (move) the unversioned file to the hashed name to save S3 space.
*   **The Failure**: If Worker A renames `post-1510.css` to `post-1510.HASH.css`, Worker B (hitting a secondary page at the same millisecond) will find the source file **missing** and fail its own hashing process.
*   **The Rule**: The unversioned file must remain as a **read-only template** for all parallel workers until the bake is finalized. Hashed files are immutable and must not be deleted, preserving compatibility with older artifacts.

## 21. Native Elementor CSS Architecture (Investigation)
*   **The Issue**: Theoretical uncertainty about "multi-phase" writing where placeholders might be written to disk.
*   **The Research**: A review of `Elementor\Core\Files\CSS\Base` and `Post` classes (v3.25.0) confirms that Elementor generates CSS strings in-memory and writes them using a single `file_put_contents` call.
*   **The Lesson**: There is no native "template phase" on disk. If `{{WRAPPER}}` appears in an artifact, it is a sign of a failed memory-replacement loop or a process abortion.
*   **The "Done" Metric**: The `Elementor\Stylesheet` rendering engine is deterministic; every selector block is wrapped in braces. Therefore, `count('{') === count('}')` is a high-fidelity test for a complete file, far superior to file size or age.
*   **Query String Myths**: Elementor's native `?ver=` is tied to the file's modification timestamp, not the plugin code version. Our MD5 content-hashing is the most stable approach for CDN consistency.
