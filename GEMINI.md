# Project Constraints & Requirements

## Audit Tooling (test-artifact.sh)

- **Site-Agnosticism**: The script MUST NOT contain hardcoded Site IDs or project-specific domains (e.g., `nationalcpc.org`). All site identification must be provided via CLI arguments (`--site-id`) or environment variables.
- **Resilient Parallelism**: Background workers in the audit loop MUST be insulated from `set -e` termination when performing structural comparisons. Use separate variable assignments for `local` declarations and append `|| true` to filtered `grep` commands to handle zero-regression cases safely.
- **Normalization Fidelity**: Structural comparisons MUST use the `tidy-html` and `xmldiff` pipeline. Masking patterns MUST include case-insensitive hex IDs (`elementor-element-[a-f0-9]+`), repeater IDs, and ephemeral attributes (e.g., `data-olk-copy-source`).
- **Environmental Noise Filtering**: Always filter out terminal/shell noise and blank lines from `xmldiff` output. Neutralize dynamic scripts from 3rd-party plugins (*Optimization Detective*, *Algolia*) and minified Elementor snippets using multi-line Perl regex (`-0777` slurp mode).
- **Targeted Diagnostic Capabilties**: The script MUST support specific subpage auditing via the `--pages` CSV argument to allow verification of individual layouts without full site-wide audits.
- **Dependency Contract**: The audit tool requires `jq`, `curl`, `tidy-html`, `python-xmldiff`, and `perl`.

## WordPress Plugin (elementor-fix.php)

- **File Locking**: Use `fopen(..., 'x')` (Exclusive Create) for S3-native atomic file creation. DO NOT use `flock()`, as it is silently ignored by the Shifter S3 stream wrapper.
- **Master Registry Pattern**: Use the WordPress database (e.g. `shifter_css_hashes` option) as the central registry for `post_id => hash` mappings. Workers MUST check the database before performing redundant `md5_file()` or S3 `stat()` operations.
- **Content-Based Hashing**: Use MD5 content hashes for stylesheet versioning. Version strings from query parameters (e.g. `?ver=3.21`) MUST be extracted and moved into the physical filename (e.g. `post-1510.v3.2.1.HASH.css`).
- **Strict Audit Enforcement**: The audit tool MUST treat any unversioned Elementor CSS link as a CRITICAL FAILURE (Stale Content Risk), even if the file returns 200 OK. Fallback to unversioned URLs is prohibited.
- **Persistence & Consistency**: Hashed CSS files are immutable and MUST NOT be deleted. This preserves the integrity of older static artifacts and ensures parallel bake workers always have access to shared asset templates.
- **Shifter Media CDN Role**: The CDN (`cdn.getshifter.co`) is an immutable, write-only S3 symlink. It is used intentionally to prevent static artifact bloat. Because CSS files are uniquely hashed, Elementor updates do not overwrite older artifact versions, making them safe for CDN offloading. The bake intentionally skips CSS compilation into the zip.

## Structural & Integrity Findings (Elementor Core Review)

- **Single-Shot Integrity**: Elementor writes the finalized CSS to disk in a single `file_put_contents` call. There is no intermediate "template" phase on disk; placeholders like `{{WRAPPER}}` are swapped in memory. 
- **Brace Balance Guarantee**: The `Elementor\Stylesheet` class explicitly wraps every selector in braces. A mathematically certain integrity check for a completed render is `count('{') === count('}')`. Any mismatch indicates a truncated write or PHP crash.
- **Canary Detection**: The presence of `{{WRAPPER}}` in a physical file is a "Canary" for a catastrophic pipeline failure (rendering aborting before placeholder substitution).
- **Versioning Logic**: Elementor natively uses Unix timestamps for its `?ver=` query parameters. Our MD5 content-hashing is superior as it remains immutable across bakes if the content is identical.
