#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/caloriecapture-search-tests.XXXXXX")"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

xcrun swiftc -sdk "$sdk_path" -target "$(uname -m)-apple-macosx14.0" \
    -swift-version 5 \
    "$repo_dir/CalorieCop/Models/NutritionInfo.swift" \
    "$repo_dir/CalorieCop/Models/FoodEntry.swift" \
    "$repo_dir/CalorieCop/Models/FoodPreference.swift" \
    "$repo_dir/tools/search-tests/HistorySearchTests.swift" \
    -o "$test_dir/history-search-tests"
"$test_dir/history-search-tests"
