"""Unit tests for scripts/generate-pvekit-api.py (run: python3 -m unittest discover scripts/tests)."""
import importlib.util
import pathlib
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "generate-pvekit-api.py"
spec = importlib.util.spec_from_file_location("generator", SCRIPT)
generator = importlib.util.module_from_spec(spec)
sys.modules["generator"] = generator
spec.loader.exec_module(generator)


class NamingTests(unittest.TestCase):
    def test_request_type_names(self):
        name = generator.request_type_name
        self.assertEqual(name("/nodes/{node}/qemu/{vmid}/status/current", "GET"), "GetNodesQemuStatusCurrent")
        self.assertEqual(name("/nodes/{node}/qemu/{vmid}/snapshot/{snapname}", "DELETE"), "DeleteNodesQemuSnapshotBySnapname")
        self.assertEqual(name("/nodes/{node}/query-url-metadata", "GET"), "GetNodesQueryUrlMetadata")
        self.assertEqual(name("/nodes", "GET"), "GetNodes")
        self.assertEqual(name("/nodes/{node}", "GET"), "GetNodesByNode")
        self.assertEqual(name("/a/{x}/b/{y}", "PUT", include_all_params=True), "PutAByXBByY")

    def test_identifiers(self):
        self.assertEqual(generator.lower_camel("verify-certificates"), "verifyCertificates")
        self.assertEqual(generator.lower_camel("CSRFPreventionToken"), "csrfPreventionToken")
        self.assertEqual(generator.lower_camel("Datastore.Allocate"), "datastoreAllocate")
        self.assertEqual(generator.upper_camel("4M"), "_4M")
        self.assertEqual(generator.escape_identifier("default"), "`default`")
        taken = set()
        self.assertEqual(generator.member_name("path", taken), "pathParam")
        self.assertEqual(generator.member_name("foo", taken), "foo")
        self.assertEqual(generator.member_name("foo", taken), "foo2")

    def test_file_groups(self):
        self.assertEqual(generator.file_group("/nodes/{node}/qemu/{vmid}/config"), "Nodes+Qemu")
        self.assertEqual(generator.file_group("/cluster/sdn/vnets"), "Cluster+Sdn")
        self.assertEqual(generator.file_group("/access/users"), "Access")


class OutputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import json
        cls.files = generator.Generator(json.loads(generator.SCHEMA.read_text(encoding="utf-8"))).files()

    def test_snapshot_create(self):
        text = self.files["PVEAPI+Nodes+Qemu.swift"]
        start = text.index("public struct PostNodesQemuSnapshot:")
        body = text[start:text.index("\n    }\n", start)]
        self.assertIn('public static let pathTemplate = "/nodes/{node}/qemu/{vmid}/snapshot"', body)
        self.assertIn("public init(node: String, vmid: Int, snapname: String)", body)
        self.assertIn("public var vmstate: Bool?", body)
        self.assertIn('if let value = vmstate { result.append(("vmstate", value.parameterValue)) }', body)
        self.assertIn("public typealias Response = String", body)

    def test_enum_and_typed_response(self):
        text = self.files["PVEAPI+Nodes.swift"]
        start = text.index("public struct GetNodesRrddata:")
        body = text[start:text.index("\n    }\n", start)]
        self.assertIn("public enum Timeframe: String", body)
        self.assertIn('case hour = "hour"', body)
        self.assertIn("public typealias Response = JSONValue", body, "no item properties in the schema")
        start = text.index("public struct GetNodesServices:")
        body = text[start:text.index("\n    }\n", start)]
        self.assertIn("public typealias Response = [Item]", body)
        self.assertIn("public struct Item: Decodable, Sendable, Hashable", body)

    def test_deterministic(self):
        import json
        again = generator.Generator(json.loads(generator.SCHEMA.read_text(encoding="utf-8"))).files()
        self.assertEqual(again, self.files)


if __name__ == "__main__":
    unittest.main()
