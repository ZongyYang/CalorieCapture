import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from order_bridge import parse_order


class ParseOrderTests(unittest.TestCase):
    def test_returns_only_valid_food_items(self):
        item = {
            "food_name": "Chicken rice bowl", "brand": "", "grams": 350,
            "calories": 550, "protein": 38, "carbohydrates": 65, "fat": 15,
            "confidence": "medium", "notes": "Estimate", "days_ago": 0,
        }

        def fake_run(command, **_):
            output = Path(command[command.index("--output-last-message") + 1])
            output.write_text(json.dumps({"items": [item]}), encoding="utf-8")
            return subprocess.CompletedProcess(command, 0)

        with patch("order_bridge.subprocess.run", side_effect=fake_run):
            self.assertEqual(parse_order(b"\xff\xd8\xff", ""), {"items": [item]})

    def test_rejects_negative_nutrition(self):
        def fake_run(command, **_):
            output = Path(command[command.index("--output-last-message") + 1])
            output.write_text(json.dumps({"items": [{"food_name": "Test", "grams": 100, "calories": -1,
                                                    "protein": 0, "carbohydrates": 0, "fat": 0}]}),
                              encoding="utf-8")
            return subprocess.CompletedProcess(command, 0)

        with patch("order_bridge.subprocess.run", side_effect=fake_run):
            with self.assertRaises(ValueError):
                parse_order(b"\xff\xd8\xff", "")


if __name__ == "__main__":
    unittest.main()
