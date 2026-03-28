## Full-Lifecycle Regression Audit

The script can automate the entire Shifter deployment cycle and perform side-by-side HTML diffing against the live staging environment.

### 1. The Audit Cycle (`--bake`)
Triggering a full cycle:
```bash
./test-artifact.sh --bake --deep-audit --sample 10
```
**Workflow**:
1.  **Stop WordPress**: Prepares the environment for a bake.
2.  **Start Bake**: Triggers artifact generation and logs the total duration.
3.  **Activate Preview**: Provisions the static environment for testing.
4.  **Restart WordPress**: Automatically brings the staging site back to `inservice`.
5.  **Deep Audit**: Performs side-by-side HTML diffs (Artifact vs. Staging).

### 2. Side-by-Side Diffing (`--deep-audit`)
In this mode, the script downloads matching pages from both environments and stores them in:
`.artifacts/<artifact_id>/<page-slug>/`

-   **Parallel Workers**: Uses up to 8 concurrent processes to speed up comparison.
-   **Automated Cleanup**: If the pages are identical, the folder is deleted.
-   **Reviewing Issues**: If `diff.txt` exists for a slug, it means there is an HTML discrepancy (e.g., stale content or structural generation errors).

## Security & Environment Configuration

The script uses a git-ignored `.env` file for credential and token management. This ensures your sensitive information stays local to your environment.

### Tiered Authentication Flow

1.  **Token Reuse**: If `SHIFTER_ACCESS_TOKEN` is found in `.env` and is not expired, the script uses it immediately (fastest).
2.  **Auto-Renewal**: If the token is missing or expired, the script checks for `SHIFTER_USER` and `SHIFTER_PASS` in your environment or `.env` file.
3.  **Interactive Prompt**: If no credentials are found, the script will prompt you in the terminal. Passwords are entered securely using `read -s`.

### Example `.env` File
```bash
# Optional: Provide these for zero-interaction auto-renewal
SHIFTER_USER="your-email@example.com"
SHIFTER_PASS="your-password"

# Automatically managed by the script
SHIFTER_ACCESS_TOKEN="eyJraW..."
```

## Requirements
*   `jq`: Required for Shifter API and JWT parsing.
*   `curl`: Required for network requests.
*   `base64`: Required for token validation.
