# Project Constraints & Requirements

## Audit Tooling (test-artifact.sh)

- **Site-Agnosticism**: The script MUST NOT contain hardcoded Site IDs or project-specific domains (e.g., `nationalcpc.org`). All site identification must be provided via CLI arguments (`--site-id`) or environment variables.
- **Resilient Parallelism**: Background workers in the audit loop MUST be insulated from `set -e` termination when performing structural comparisons. Use separate variable assignments for `local` declarations and append `|| true` to filtered `grep` commands to handle zero-regression cases safely.
- **Normalization Fidelity**: Structural comparisons MUST use the `tidy-html` and `xmldiff` pipeline. Masking patterns MUST include case-insensitive hex IDs (`elementor-element-[a-f0-9]+`), repeater IDs, and ephemeral attributes (e.g., `data-olk-copy-source`).
- **Environmental Noise Filtering**: Always filter out terminal/shell noise and blank lines from `xmldiff` output. Neutralize dynamic scripts from 3rd-party plugins (*Optimization Detective*, *Algolia*) and minified Elementor snippets using multi-line Perl regex (`-0777` slurp mode).
- **Targeted Diagnostic Capabilties**: The script MUST support specific subpage auditing via the `--pages` CSV argument to allow verification of individual layouts without full site-wide audits.
- **Dependency Contract**: The audit tool requires `jq`, `curl`, `tidy-html`, `python-xmldiff`, and `perl`.

## WordPress Plugin (elementor-fix.php)

- **File Locking**: Use `flock` to prevent race conditions during parallel CSS generation in the Shifter build process.
- **Content-Based Hashing**: Use MD5 content hashes for stylesheet versioning to ensure cache-friendly, unique filenames across builds.
- **Shifter Media CDN Role**: The CDN (`cdn.getshifter.co`) is an immutable, write-only S3 symlink. It is used intentionally to prevent static artifact bloat. Because CSS files are uniquely hashed, Elementor updates do not overwrite older artifact versions, making them safe for CDN offloading. The bake intentionally skips CSS compilation into the zip.
