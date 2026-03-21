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
- **AI Advisor**: Chat with AI about your diet and weight loss progress (with conversation history and auto-compression)
- **SwiftData Persistence**: All food entries stored locally on device
- **In-App API Key Setup**: Configure API keys directly in the app with region selection (China/International)

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Apple Watch (optional, for activity tracking)
- MiniMax API key (required for text food parsing and AI advisor)
- Qwen API key (optional, for image food recognition)

## Setup

### 1. Clone the repository

```bash
git clone <repository-url>
cd CalorieCop
```

### 2. Install Xcode (if not already installed)

1. Open the App Store on your Mac
2. Search for "Xcode" and install it (requires macOS 13.5+)
3. After installation, open Xcode once to complete setup
4. Install Command Line Tools: `xcode-select --install`

### 3. Open Project in Xcode

1. Open `CalorieCop.xcodeproj` in Xcode:
   ```bash
   open CalorieCop.xcodeproj
   ```
2. Wait for Xcode to index the project

### 4. Configure Signing

1. Select the **CalorieCop** project in the navigator
2. Select the **CalorieCop** target
3. Go to **Signing & Capabilities** tab
4. Check **Automatically manage signing**
5. Select your **Team**:
   - For personal use: Select your Apple ID (Personal Team)
   - For distribution: Select your Apple Developer account
6. Xcode will automatically create a provisioning profile

> **Note**: If you don't have a team, click "Add Account..." and sign in with your Apple ID.

### 5. Build and Run

**For Simulator:**
1. Select a simulator from the device dropdown (e.g., iPhone 15 Pro)
2. Press `Cmd + R` to build and run

**For Physical Device:**
1. Connect your iPhone via USB or select it over Wi-Fi
2. Trust your computer on the device if prompted
3. Press `Cmd + R` to build and run
4. On first run, go to **Settings → General → VPN & Device Management** on your iPhone to trust the developer certificate

### 6. Configure API Keys (In-App)

When you first open the app and go to "记录食物" (Food Input), you'll see an API key setup prompt:

1. **Select Region**:
   - **International**: For users outside China (uses `.io` and `dashscope-intl` endpoints)
   - **China**: For users in mainland China (uses `.chat` and `dashscope` endpoints)

2. **MiniMax API Key** (Required):
   - International: Visit [minimax.io](https://www.minimax.io)
   - China: Visit [minimaxi.com](https://www.minimaxi.com)
   - Create an account → Go to Console → API Keys → Create new key

3. **Qwen API Key** (Optional - for image recognition):
   - International: Visit [Alibaba Cloud DashScope](https://www.alibabacloud.com/product/dashscope)
   - China: Visit [阿里云 DashScope](https://dashscope.console.aliyun.com)
   - Create an account → Go to API-KEY Management → Create new key

4. Tap the clipboard icon to paste your key, or type it manually
5. Click "保存设置" to save

> **Note**: API keys are stored locally on your device and never uploaded to any server.

### Alternative: Configure via Secrets.swift (For Developers)

If you prefer to hardcode API keys (useful for development):

1. Copy `Secrets.swift.template` to `Secrets.swift`:
   ```bash
   cp CalorieCop/Services/Secrets.swift.template CalorieCop/Services/Secrets.swift
   ```

2. Edit `Secrets.swift` and add your API keys:
   ```swift
   enum Secrets {
       static let miniMaxAPIKey = "your_minimax_api_key"
       static let qwenAPIKey = "your_qwen_api_key"
   }
   ```

3. The app will use these keys as fallback if no user keys are configured.

## Usage

1. **Record Food**: Tap the "记录" tab and describe what you ate, or take a photo
2. **Review & Confirm**: Check the AI-parsed nutrition and confirm
3. **Track Progress**: View your daily summary on the "今日" tab
4. **AI Advisor**: Chat with AI about your diet (tap "AI顾问" in History tab)
5. **Monitor Balance**: See calories consumed vs burned

## Project Structure

```
CalorieCop/
├── App/
│   ├── CalorieCopApp.swift      # App entry point
│   └── ContentView.swift         # Main tab view
├── Models/
│   ├── FoodEntry.swift           # SwiftData model
│   ├── NutritionInfo.swift       # Nutrition data struct
│   ├── UserGoal.swift            # Weight goals
│   ├── ChatMessage.swift         # AI chat history
│   └── FoodPreference.swift      # Saved food preferences
├── Services/
│   ├── AIService/
│   │   ├── AIServiceProtocol.swift
│   │   ├── MiniMaxService.swift
│   │   └── FoodParsingPrompt.swift
│   ├── HealthKitService.swift
│   ├── APIKeyManager.swift       # API key & region management
│   └── Secrets.swift             # (gitignored) Developer API keys
├── Views/
│   ├── FoodInput/
│   │   ├── FoodInputView.swift
│   │   └── FoodConfirmationView.swift
│   ├── Dashboard/
│   │   ├── DashboardView.swift
│   │   └── FoodListView.swift
│   ├── History/
│   │   ├── HistoryView.swift
│   │   └── AIAdvisorView.swift
│   ├── Goals/
│   │   └── GoalsView.swift
│   ├── Settings/
│   │   └── APIKeySetupView.swift  # In-app API key configuration
│   └── Components/
│       ├── NutritionCard.swift
│       └── CalorieBalanceView.swift
└── Utilities/
    └── Extensions.swift
```

## API Reference

### MiniMax API (Text Parsing & AI Chat)

| Region | Endpoint |
|--------|----------|
| International | `https://api.minimax.io/v1/text/chatcompletion_v2` |
| China | `https://api.minimax.chat/v1/text/chatcompletion_v2` |

- Model: `MiniMax-M2.7-highspeed`
- Used for: Text food parsing, AI advisor chat
- Features: Streaming responses, fast inference
- Get API key: [minimax.io](https://www.minimax.io) or [minimaxi.com](https://www.minimaxi.com)

### Qwen VL Plus (Image Recognition)

| Region | Endpoint |
|--------|----------|
| International | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions` |
| China | `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` |

- Model: `qwen-vl-plus`
- Used for: Camera/photo food recognition
- Supports: Multiple foods in single image
- Get API key: [DashScope Console](https://dashscope.console.aliyun.com/)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Signing requires a development team" | Select a team in Signing & Capabilities |
| "Unable to install app" | Trust the developer certificate on your device |
| HealthKit data not showing | Use a physical device with Apple Watch paired |
| "需要设置 API 密钥" | Configure API keys in Settings (gear icon) |
| API calls failing | Verify API keys and check region setting |
| AI returns empty | Check internet connection and API key validity |

## Privacy

- All food data is stored locally on your device using SwiftData
- API keys are stored locally in UserDefaults (never uploaded)
- HealthKit data never leaves your device
- API calls only send food descriptions (no personal data)

## License

MIT License
