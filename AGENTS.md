# CalorieCapture development agreement

## Delivery workflow

For every source-code or Xcode-project configuration change:

1. Implement the requested change and run the appropriate build.
2. Install the successful build on the connected iPhone, keeping bundle identifier `com.zyyang116.caloriecapture` unchanged.
3. Verify that installation succeeds; preserve the existing app container and its local data.
4. Inspect the relevant diff, create a focused Git commit, and push the current branch to `origin`.

If the build or installation fails, do not commit or push the affected code as a completed delivery. Explain the failure and resolve it first. Do not include unrelated or personal-data files in a commit, especially `CalorieCop/Resources/migration_data.json` or API keys.

Documentation-only changes do not require an iPhone build. State clearly that no app build or installation was needed.

## Working across Macs

Before making changes, fetch and check the current branch, working tree, and upstream state. On a second Mac, update the repository with a fast-forward pull before opening a new Codex session. Do not overwrite, reset, or discard existing work without explicit user authorization.
