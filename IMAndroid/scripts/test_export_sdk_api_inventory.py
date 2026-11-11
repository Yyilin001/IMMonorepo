import copy
import json
from pathlib import Path
import tempfile
import unittest

from export_sdk_api_inventory import (SOURCE_ROOT, check_inventory, encode_records,
                                      export_inventory, normalize_graph)


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name).resolve()
        source = self.repo / SOURCE_ROOT / "Public.swift"
        source.parent.mkdir(parents=True)
        source.write_text("public struct Sample {}\n")
        generated = source.parent / "Generated" / "sample.pb.swift"
        generated.parent.mkdir()
        generated.write_text("public struct ProtocolSample {}\n")
        self.graph = {"module": {"name": "IMV2ClientKit"}, "metadata": {}, "symbols": [
            self.symbol("first", source), self.symbol("generated", generated), self.symbol("unlocated", None)]}

    def symbol(self, name, path):
        result = {"identifier": {"precise": name}, "kind": {"identifier": "swift.struct"},
                  "pathComponents": [name], "accessLevel": "public",
                  "declarationFragments": [{"spelling": f"struct {name}"}]}
        if path:
            result["location"] = {"uri": path.as_uri(), "position": {"line": 0, "character": 0}}
        return result

    def export(self):
        path = self.repo / "graph.json"
        path.write_text(json.dumps(self.graph))
        output = self.repo / "inventory"
        export_inventory(path, self.repo, output)
        return output

    def test_compiler_order_does_not_change_inventory_and_categories_stay_distinct(self):
        records = normalize_graph(self.graph, self.repo)
        shuffled = copy.deepcopy(self.graph)
        shuffled["symbols"].reverse()
        self.assertEqual(encode_records(records), encode_records(normalize_graph(shuffled, self.repo)))
        self.assertEqual({r["category"] for r in records}, {"generated", "handwritten", "unlocated"})
        self.assertEqual(next(r for r in records if r["id"] == "first")["line"], 1)
        self.assertNotIn(str(self.repo), encode_records(records).decode())
        check_inventory(self.repo, self.export())

    def test_rejects_duplicate_and_non_public_symbols(self):
        for mutation in (lambda g: g["symbols"].append(g["symbols"][0]),
                         lambda g: g["symbols"][0].update(accessLevel="internal")):
            graph = copy.deepcopy(self.graph)
            mutation(graph)
            with self.assertRaises(ValueError):
                normalize_graph(graph, self.repo)

    def test_rejects_source_outside_module_and_remote_uri(self):
        for uri in ((self.repo / "outside.swift").as_uri(), "https://example.invalid/Public.swift"):
            graph = copy.deepcopy(self.graph)
            graph["symbols"][0]["location"]["uri"] = uri
            with self.assertRaises(ValueError):
                normalize_graph(graph, self.repo)

    def test_detects_changed_added_and_deleted_sources(self):
        source = self.repo / SOURCE_ROOT / "Public.swift"
        for change in (lambda: source.write_text("changed"),
                       lambda: (source.parent / "New.swift").write_text("new"), source.unlink):
            output = self.export()
            change()
            with self.assertRaisesRegex(ValueError, "stale"):
                check_inventory(self.repo, output)
            source.write_text("public struct Sample {}\n")
            (source.parent / "New.swift").unlink(missing_ok=True)

    def test_detects_inventory_tampering(self):
        output = self.export()
        with (output / "swift-public-api.jsonl").open("ab") as file:
            file.write(b"{}\n")
        with self.assertRaisesRegex(ValueError, "Inventory changed"):
            check_inventory(self.repo, output)


if __name__ == "__main__":
    unittest.main()
