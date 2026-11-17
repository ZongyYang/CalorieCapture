import Foundation

// Compile against the production models; fixtures never touch a phone's store.
// Run with: bash tools/search-tests/run.sh
@main
enum HistorySearchTests {
    static func entry(_ name: String, brand: String? = nil, daysAgo: Int) -> FoodEntry {
        FoodEntry(
            rawInput: name, foodName: name, brand: brand, grams: 100,
            calories: 120, protein: 6, carbohydrates: 15, fat: 4,
            date: Date(timeIntervalSince1970: 1_800_000_000 - Double(daysAgo) * 86_400)
        )
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        print("PASS: \(message)")
    }

    static func main() {
        let old = entry("燕麦牛奶", brand: "历史品牌", daysAgo: 120)
        let yesterday = entry("燕麦拿铁", brand: "咖啡店", daysAgo: 1)
        let today = entry("燕麦粥", daysAgo: 0)
        let items = [old, today, yesterday]
        let originalDates = items.map(\.createdAt)

        expect(
            items.unsavedSearchSuggestions(matching: "燕麦", excluding: []).map(\.id)
                == [today.id, yesterday.id, old.id],
            "Includes today, yesterday and older history, newest first"
        )
        expect(
            items.unsavedSearchSuggestions(matching: "历史品牌", excluding: []).map(\.id) == [old.id],
            "Finds historical entries by brand"
        )

        let saved = FoodPreference(entry: yesterday)
        expect(
            items.unsavedSearchSuggestions(matching: "燕麦", excluding: [saved]).map(\.id)
                == [today.id, old.id],
            "Excludes entries already saved as habits"
        )

        let oldDuplicate = entry(" LATTE ", brand: "Cafe", daysAgo: 90)
        let recentDuplicate = entry("latte", brand: "CAFE", daysAgo: 2)
        let otherBrand = entry("Latte", brand: "Other Cafe", daysAgo: 3)
        let duplicates = [oldDuplicate, otherBrand, recentDuplicate]
        expect(
            duplicates.unsavedSearchSuggestions(matching: "  LaTTe \n", excluding: []).map(\.id)
                == [recentDuplicate.id, otherBrand.id],
            "Trims query, ignores case and deduplicates by name plus brand using latest entry"
        )
        expect(
            duplicates.unsavedSearchSuggestions(
                matching: "latte", excluding: [FoodPreference(entry: oldDuplicate)]
            ).map(\.id) == [otherBrand.id],
            "Saved habit matching excludes older and newer duplicates but keeps other brands"
        )

        let unbrandedEgg = entry("蒸蛋", daysAgo: 30)
        let brandedEgg = entry("蒸蛋", brand: "乡村基", daysAgo: 1)
        let savedEgg = FoodPreference(entry: brandedEgg)
        expect(
            [unbrandedEgg, brandedEgg].unsavedSearchSuggestions(matching: "蒸蛋", excluding: [savedEgg]).isEmpty,
            "Saved branded habit takes precedence over both branded and unbranded intake history"
        )
        expect(
            [brandedEgg].unsavedSearchSuggestions(
                matching: "蒸蛋", excluding: [FoodPreference(entry: unbrandedEgg)]
            ).isEmpty,
            "Saved unbranded habit also takes precedence over the same named branded entry"
        )
        expect(!savedEgg.matches(keyword: unbrandedEgg.foodName, brand: unbrandedEgg.brand),
               "Search de-duplication does not relax stored-data update or deletion matching")

        let largerServing = entry("蒸蛋", daysAgo: 0)
        largerServing.grams = 250
        largerServing.calories = 300
        expect(
            [largerServing].unsavedSearchSuggestions(matching: "蒸蛋", excluding: [savedEgg]).isEmpty,
            "Different serving quantities and calories do not create duplicate search suggestions"
        )
        let formattedLatte = FoodPreference(entry: entry(" LATTE ", brand: " CAFE ", daysAgo: 3))
        expect(
            [recentDuplicate].unsavedSearchSuggestions(matching: "latte", excluding: [formattedLatte]).isEmpty,
            "Saved-food identity ignores case and surrounding whitespace"
        )
        let spacedEgg = FoodPreference(entry: entry(" 蒸蛋 ", brand: " 乡村基 ", daysAgo: 2))
        expect(spacedEgg.representsSearchEntry(foodName: "蒸蛋", brand: nil),
               "Surrounding whitespace does not prevent saved-food priority")
        let otherEgg = entry("虾仁蒸蛋", brand: "乡村基", daysAgo: 2)
        let anotherBrandEgg = entry("蒸蛋", brand: "另一家店", daysAgo: 3)
        expect(
            [unbrandedEgg, otherEgg, anotherBrandEgg].unsavedSearchSuggestions(
                matching: "蒸蛋", excluding: [savedEgg]
            ).map(\.id) == [otherEgg.id, anotherBrandEgg.id],
            "Similar food names and explicit different brands remain available"
        )
        expect(
            [unbrandedEgg].unsavedSearchSuggestions(matching: "蒸蛋", excluding: []).map(\.id) == [unbrandedEgg.id],
            "Historical suggestion becomes available again when the habit is no longer saved"
        )
        expect(
            [brandedEgg].unsavedSearchSuggestions(
                matching: "乡村基", excluding: [FoodPreference(entry: unbrandedEgg)]
            ).map(\.id) == [brandedEgg.id],
            "Brand-only search never hides a record when its unbranded habit is not a search match"
        )
        expect(savedEgg.matchesSearchQuery(" 蒸蛋 \n") && savedEgg.matchesSearchQuery("乡村基"),
               "Saved-habit filtering uses the same trimmed query as duplicate exclusion")
        expect(!savedEgg.matchesSearchQuery(" \n ") && !savedEgg.matchesSearchQuery("拿铁"),
               "Unrelated and blank searches do not match saved habits")

        let fourth = entry("燕麦饼", daysAgo: 10)
        expect(
            (items + [fourth]).unsavedSearchSuggestions(matching: "燕麦", excluding: []).map(\.id)
                == [today.id, yesterday.id, fourth.id],
            "Default limit remains three distinct recent foods"
        )
        expect(
            items.unsavedSearchSuggestions(matching: "燕麦", excluding: [], limit: 1).map(\.id)
                == [today.id],
            "Supports an explicit result limit"
        )
        expect(items.unsavedSearchSuggestions(matching: "燕麦", excluding: [], limit: 0).isEmpty,
               "Zero limit returns no suggestions")
        expect(items.unsavedSearchSuggestions(matching: "燕麦", excluding: [], limit: -1).isEmpty,
               "Negative limit returns no suggestions")
        expect(items.unsavedSearchSuggestions(matching: " \n ", excluding: []).isEmpty,
               "Blank query returns no suggestions")
        expect(items.unsavedSearchSuggestions(matching: "不存在的食物", excluding: []).isEmpty,
               "Unmatched query returns no suggestions")
        expect([FoodEntry]().unsavedSearchSuggestions(matching: "燕麦", excluding: []).isEmpty,
               "Empty history returns no suggestions")
        expect(items.map(\.createdAt) == originalDates && saved.usageCount == 1,
               "Searching never changes historical timestamps or saved habits")
    }
}
