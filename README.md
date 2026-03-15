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

### 3. Configure API Keys

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

### 3. Enable HealthKit

1. Open the project in Xcode
2. Select the CalorieCop target
3. Go to "Signing & Capabilities"
4. Click "+ Capability" and add "HealthKit"
5. Check "Clinical Health Records" if needed

### 4. Build and Run

1. Select your target device or simulator
2. Press Cmd+R to build and run

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
