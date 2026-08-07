# CalorieCapture / CalorieCop - Codex Handoff

This document is the working context for continuing development on another Mac or in another Codex session.

## Project Identity

- Repository: `https://github.com/ZongyYang/CalorieCapture.git`
- Original upstream: `https://github.com/kaka-jun/CalorieCop.git`
- Xcode project: `CalorieCop.xcodeproj`
- Scheme: `CalorieCop`
- Product name shown to the user: `CalorieCapture`
- Bundle identifier: `com.zyyang116.caloriecapture`
- Deployment target: iOS 17.0+
- UI language: Simplified Chinese
- Architecture: SwiftUI + SwiftData + HealthKit + Swift Charts

Keep the bundle identifier unchanged when installing updates to the existing phone app. Changing it creates a separate app container and the old records will not appear in the new app.

## Current App Areas

- `今日`: daily intake, HealthKit resting/activity/total energy, calorie balance, nutrition cards, today's food records, and the shared food search/AI/photo input.
- `记录`: manual intake, AI/photo recognition, saved food habits, unit and total nutrition input, brand suggestions, and quick recording from a saved habit.
- `统计`: calorie statistics, nutrition statistics, weight trend, and goal progress. The top toolbar is AI advisor on the left and Settings on the right.
- `历史`: day summaries, food details, editing/deleting records, AI nutrition completion, saved-habit actions, and AI advisor.
- `设置`: target settings, API settings, and saved food habits. Saved habits can be searched, edited, recorded, and deleted by swipe.

## Important Source Locations

- `CalorieCop/App/ContentView.swift`: tab navigation and app-level view composition.
- `CalorieCop/Views/Dashboard/DashboardView.swift`: 今日 page, balance, HealthKit summary, and today's records.
- `CalorieCop/Views/Dashboard/FoodListView.swift`: today's food list and nutrition completion.
- `CalorieCop/Views/FoodInput/FoodInputView.swift`: record intake flow, search, manual entry, saved habits, and habit editing.
- `CalorieCop/Views/FoodInput/FoodConfirmationView.swift`: AI result review and parallel record/save-habit actions.
- `CalorieCop/Views/History/DayDetailView.swift`: history detail, record editing, swipe delete, nutrition completion, and habit merging.
- `CalorieCop/Views/History/AIAdvisorView.swift`: AI advisor chat, photo/text input, copy/share/delete actions, and chat history.
- `CalorieCop/Views/Goals/GoalsView.swift`: 统计 page and statistics charts.
- `CalorieCop/Views/Goals/WeightChartView.swift`: weight trend chart.
- `CalorieCop/Views/Components/CalorieBalanceView.swift`: shared calorie balance card and `AppSurfaceStyle` colors.
- `CalorieCop/Views/Settings/APIKeySetupView.swift`: Settings page and API key configuration.
- `CalorieCop/Models/FoodEntry.swift`: food record model and nutrition/unit behavior.
- `CalorieCop/Models/FoodPreference.swift`: saved food habit model and per-unit nutrition data.
- `CalorieCop/Services/HealthKitService.swift`: HealthKit authorization and daily resting/activity energy.
- `CalorieCop/Services/APIKeyManager.swift`: local API key and region management.
- `CalorieCop/Services/AIService/`: MiniMax text/advisor and Qwen-compatible image parsing.

## UI Surface Rules

`AppSurfaceStyle` is defined in `CalorieCop/Views/Components/CalorieBalanceView.swift` and is the shared source for page/card colors:

- Light page: grouped gray background.
- Light card: white.
- Light form module: a darker grouped gray so the module remains visible against the page.
- Dark page: black.
- Dark card/form module: the same dark gray used by the record page.
- Form input surfaces: white in light mode and black in dark mode.

When adding a new page or editing form, use these shared colors instead of introducing a new hard-coded background. Preserve the existing rounded module/card hierarchy and high-contrast primary text.

## Data and Privacy

- Food entries, saved habits, goals, weights, and chat messages are stored locally with SwiftData on the device.
- HealthKit data stays on the device and is read through HealthKit.
- API keys are configured in-app and must never be committed to GitHub.
- `CalorieCop/Resources/migration_data.json` is a local personal-data export and is intentionally ignored by Git. Do not remove the ignore rule or upload this file.
- GitHub synchronizes source code only; it does not synchronize the phone's SwiftData container.

If the data model changes, use a deliberate SwiftData migration. Do not reset the model container or delete the app during testing unless the user explicitly accepts data loss.

## API Behavior

- MiniMax is used for text food parsing and AI advisor chat.
- Qwen-compatible vision API is used for photo/image food recognition.
- DeepSeek support is configured alongside MiniMax and Qwen in API settings where supported by the current service path.
- Text-only input must not require a photo or vision API.
- Nutrition completion can be triggered from today's records, history records, edit screens, and AI results.

Do not place real API keys in source files, commits, screenshots, or documentation.

## Build and Run

Open the project:

```bash
open CalorieCop.xcodeproj
```

For the connected iPhone, use the device destination selected by Xcode. The command-line build used for the current device is:

```bash
xcodebuild \
  -project CalorieCop.xcodeproj \
  -scheme CalorieCop \
  -destination 'id=<connected-device-udid>' \
  -configuration Debug build
```

Before a physical-device build:

1. Sign in to Xcode with the same Apple account.
2. Select the same Personal Team in `Signing & Capabilities`.
3. Keep `Automatically manage signing` enabled.
4. Keep bundle identifier `com.zyyang116.caloriecapture`.
5. Trust the Mac and enable Developer Mode on the iPhone if prompted.

The current development profile is an Xcode-managed iOS development profile. A second Mac may create its own local signing certificate/profile under the same Apple team; this is normal and does not change the app's data container.

## Git Workflow Across Macs

The current local repository has:

- `origin` pointing to `ZongyYang/CalorieCapture`.
- `upstream` pointing to the original `kaka-jun/CalorieCop` project.
- Working branch: `main`.

On the current Mac before switching computers:

```bash
git status
git add .
git commit -m "Describe the change"
git push origin main
```

On the other Mac:

```bash
git clone https://github.com/ZongyYang/CalorieCapture.git
cd CalorieCapture
open CalorieCop.xcodeproj
```

Before starting new work on either Mac, pull the latest `main`. After editing, commit and push. Avoid editing the same files on both Macs at the same time. Do not use `git reset --hard` or discard changes without checking them first.

## Verification Checklist

- Build succeeds for the intended iOS device or simulator.
- Bundle identifier remains unchanged.
- HealthKit capability and usage descriptions remain present.
- Camera/photo permissions remain present.
- API keys are not in the diff.
- `migration_data.json` remains untracked and ignored.
- Existing phone data is not erased during installation.
- Test both light and dark appearance for Today, Record, Stats, History, Settings, and edit forms.

## Known Caveats

- Xcode may print DVT device build-number or empty supported-platform warnings; these have appeared during successful device builds and are not currently blocking.
- HealthKit totals require a physical device and appropriate permissions. Simulator values are not representative of Apple Watch data.
- A Personal Team development installation may need to be rebuilt/reinstalled periodically; this is signing expiration behavior, not a data-loss event.
- Never change the bundle identifier as a workaround for signing problems unless creating a deliberately separate app and accepting a separate data container.
