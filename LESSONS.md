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
