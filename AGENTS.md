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

## Version management

- Keep `MARKETING_VERSION` as the user-facing release version, and increment `CURRENT_PROJECT_VERSION` for every source change that is built, installed to the iPhone, committed, and pushed.
- Keep the app and widget on the same build number so an installed app and its widget can be matched to one delivery.
- The app Settings page displays both the App Store-style version (`1.0 (Build N)`) and `CalorieCopSourceCommit`.
- For the final post-commit build, pass `CALORIECOP_SOURCE_COMMIT=$(git rev-parse --short HEAD)` to `xcodebuild`; use `development` only for local exploratory builds. This makes the installed iPhone build traceable to the exact GitHub commit.
