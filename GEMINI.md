# Project Constraints & Requirements

## Audit Tooling (test-artifact.sh)

- **Site-Agnosticism**: The script MUST NOT contain hardcoded Site IDs or project-specific domains (e.g., `nationalcpc.org`). All site identification must be provided via CLI arguments (`--site-id`) or environment variables.
- **Resilient Parallelism**: Background workers in the audit loop MUST be insulated from `set -e` termination when performing structural comparisons. Use separate variable assignments for `local` declarations and append `|| true` to filtered `grep` commands to handle zero-regression cases safely.
- **Normalization Fidelity**: Structural comparisons MUST use the `tidy-html` and `xmldiff` pipeline. Masking patterns MUST include case-insensitive hex IDs (`elementor-element-[a-f0-9]+`), repeater IDs, and ephemeral attributes (e.g., `data-olk-copy-source`).
- **Environmental Noise Filtering**: Always filter out terminal/shell noise (like Starship initialization errors) and blank lines from the `xmldiff` output before evaluating regressions.
- **Self-Healing Execution**: Maintain the Shifter API integration to automatically restart WordPress instances on Staging 5xx errors to prevent audit timeouts.

## WordPress Plugin (elementor-fix.php)

- **File Locking**: Use `flock` to prevent race conditions during parallel CSS generation in the Shifter build process.
- **Content-Based Hashing**: Use MD5 content hashes for stylesheet versioning to ensure cache-friendly, unique filenames across builds.
