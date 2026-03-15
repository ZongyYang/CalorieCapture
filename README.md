<p align="center">
  <img src="docs/AppIcon.png" width="200" height="200" alt="CalorieCop Icon">
</p>

<h1 align="center">CalorieCop</h1>

<p align="center">
  A personal health management iOS app for weight loss tracking with natural language food input and Apple Watch activity integration.
</p>

## Features

- **Natural Language Food Input**: Describe your food in plain Chinese (e.g., "一碗米饭，两个鸡蛋") and AI will parse the nutrition info
- **Image Food Recognition**: Take a photo of your meal and AI identifies all foods with nutrition data
- **AI-Powered Nutrition Parsing**: Uses MiniMax API (text) and Qwen VL Plus (image) for accurate calorie and macro estimation
- **Food Preferences**: Save your common foods for quick one-tap logging
- **HealthKit Integration**: Syncs with Apple Watch to track calories burned
- **Calorie Balance Tracking**: See your daily intake vs burn at a glance
- **AI Advisor**: Chat with AI about your diet and weight loss progress
- **SwiftData Persistence**: All food entries stored locally on device

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Apple Watch (optional, for activity tracking)
- MiniMax API key (for text food parsing)
- Qwen API key (for image food recognition)

## Setup

### 1. Clone the repository

```bash
git clone <repository-url>
cd CalorieCop
```

### 2. Obtain API Keys

#### MiniMax API Key (Text Parsing)
1. Go to [MiniMax Platform](https://platform.minimaxi.com/)
2. Sign up and create an account
3. Navigate to API Keys section
4. Create a new API key

#### Qwen API Key (Image Recognition)
1. Go to [Alibaba Cloud DashScope](https://dashscope.console.aliyun.com/)
2. Sign up for an Alibaba Cloud account (international version for non-China users)
3. Enable the DashScope service
4. Navigate to **API Keys** in the console
5. Create a new API key
6. Note: Use the international endpoint (`dashscope-intl.aliyuncs.com`) for users outside China

### 3. Configure API Keys in Project

The app uses MiniMax API for text parsing and Qwen API for image recognition.

**Option A: Using Secrets.swift (Recommended)**

1. Copy `Secrets.swift.template` to `Secrets.swift`
2. Add your API keys:
```swift
enum Secrets {
    static let miniMaxAPIKey = "your_minimax_api_key"
    static let qwenAPIKey = "your_qwen_api_key"
}
```

**Option B: Using Environment Variables**

1. Edit the scheme (Product → Scheme → Edit Scheme)
2. Select "Run" → "Arguments" → "Environment Variables"
3. Add:
   - `MINIMAX_API_KEY`: Your MiniMax API key
   - `QWEN_API_KEY`: Your Qwen API key

### 4. Open Project in Xcode

1. Open `CalorieCop.xcodeproj` in Xcode
2. Wait for Swift Package Manager to resolve dependencies (if any)

### 5. Configure Signing

1. Select the **CalorieCop** project in the navigator
2. Select the **CalorieCop** target
3. Go to **Signing & Capabilities** tab
4. Check **Automatically manage signing**
5. Select your **Team**:
   - For personal use: Select your Apple ID (Personal Team)
   - For distribution: Select your Apple Developer account
6. Xcode will automatically create a provisioning profile

> **Note**: If you don't have a team, click "Add Account..." and sign in with your Apple ID.

### 6. Enable HealthKit

1. In **Signing & Capabilities**, click **+ Capability**
2. Search for and add **HealthKit**
3. The app requires HealthKit to read:
   - Active Energy Burned (from Apple Watch)
   - Basal Energy Burned

> **Note**: HealthKit features require a physical device. Simulator will use estimated values.

### 7. Build and Run

**For Simulator:**
1. Select a simulator from the device dropdown (e.g., iPhone 15 Pro)
2. Press `Cmd + R` to build and run

**For Physical Device:**
1. Connect your iPhone via USB or select it over Wi-Fi
2. Trust your computer on the device if prompted
3. Press `Cmd + R` to build and run
4. On first run, go to **Settings → General → VPN & Device Management** on your iPhone to trust the developer certificate

### Troubleshooting

| Issue | Solution |
|-------|----------|
| "Signing requires a development team" | Select a team in Signing & Capabilities |
| "Unable to install app" | Trust the developer certificate on your device |
| HealthKit data not showing | Use a physical device with Apple Watch paired |
| API calls failing | Verify API keys are correctly set in Secrets.swift |

## Project Structure

```
CalorieCop/
├── App/
│   ├── CalorieCopApp.swift      # App entry point
│   └── ContentView.swift         # Main tab view
├── Models/
│   ├── FoodEntry.swift           # SwiftData model
│   └── NutritionInfo.swift       # API response struct
├── Services/
│   ├── AIService/
│   │   ├── AIServiceProtocol.swift
│   │   ├── MiniMaxService.swift
│   │   └── FoodParsingPrompt.swift
│   ├── HealthKitService.swift
│   └── APIKeyManager.swift
├── Views/
│   ├── FoodInput/
│   │   ├── FoodInputView.swift
│   │   └── FoodConfirmationView.swift
│   ├── Dashboard/
│   │   ├── DashboardView.swift
│   │   └── FoodListView.swift
│   └── Components/
│       ├── NutritionCard.swift
│       └── CalorieBalanceView.swift
└── Utilities/
    └── Extensions.swift
```

## Usage

1. **Record Food**: Tap the "记录" tab and describe what you ate
2. **Review & Confirm**: Check the AI-parsed nutrition and confirm
3. **Track Progress**: View your daily summary on the "概览" tab
4. **Monitor Balance**: See calories consumed vs burned

## API Reference

### MiniMax API (Text Parsing)

- Provider: MiniMax
- Endpoint: `https://api.minimaxi.chat/v1/text/chatcompletion_v2`
- Model: `MiniMax-M2.5-highspeed` (fast text parsing, ~3s response)
- Used for: Text food input, AI advisor chat
- Response format: JSON array
- Get API key: [MiniMax Platform](https://platform.minimaxi.com/) → API Keys

### Qwen VL Plus (Image Recognition)

- Provider: Alibaba Cloud DashScope
- Endpoint (International): `https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions`
- Endpoint (China): `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`
- Model: `qwen-vl-plus`
- Used for: Camera/photo food recognition
- Supports: Multiple foods in single image
- Response format: OpenAI-compatible JSON
- Get API key: [DashScope Console](https://dashscope.console.aliyun.com/) → API Keys

## Privacy

- All food data is stored locally on your device using SwiftData
- HealthKit data never leaves your device
- API calls only send food descriptions (no personal data)

## License

MIT License
