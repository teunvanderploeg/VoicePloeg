import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).parents[2]
SPEC = importlib.util.spec_from_file_location("catalog_validation", ROOT / "Scripts/validate_model_catalog.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.items = json.loads((ROOT / "Resources/ModelCatalog.json").read_text())

    def test_shipped_catalog_is_valid(self):
        module.validate(self.items)

    def test_missing_blank_and_malformed_hashes_are_rejected(self):
        for checksum in [None, "", "UNVERIFIED", "abc", "g" * 64]:
            items = copy.deepcopy(self.items)
            items[0]["sha256"] = checksum
            with self.assertRaises((ValueError, TypeError)):
                module.validate(items)

    def test_duplicate_ids_and_invalid_capabilities_are_rejected(self):
        with self.assertRaises(ValueError):
            module.validate(self.items + [self.items[0]])
        self.items[0]["languageSupport"] = ["auto", "en"]
        with self.assertRaises(ValueError):
            module.validate(self.items)
