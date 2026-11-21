#!/usr/bin/env python3
"""Tests for `li` query and measure, on a capture of the demo's Profile screen.

The fixture is written by the demo's unit test `AgentControlTests.test_snapshotJSON_schemaAndNumbers` into
~/Library/Caches/LayoutInspector/fixtures/profile (run the InspectorDemo tests first). The expected numbers are the
ones the Spacing and Measure overlays show on that screen, and the ones the Swift test asserts.

    python3 Tools/test_li.py
"""
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LI = os.path.join(HERE, "li")
FIXTURE = os.environ.get("LI_FIXTURE") or os.path.expanduser("~/Library/Caches/LayoutInspector/fixtures/profile")


def li(*args):
    p = subprocess.run([sys.executable, LI] + list(args), capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        raise AssertionError("li %s failed (%d): %s" % (" ".join(args), p.returncode, p.stderr))
    return p.stdout


@unittest.skipUnless(os.path.isfile(os.path.join(FIXTURE, "capture.json")), "no fixture; run the demo's unit tests")
class LiTests(unittest.TestCase):
    def query(self, *selector):
        return json.loads(li("query", *selector, "--dir", FIXTURE, "--json"))

    def measure(self, a, b=None):
        return json.loads(li("measure", a, *([b] if b else []), "--dir", FIXTURE, "--json"))

    def test_query_text_font_and_component(self):
        name = self.query("--text", "Anna Petrova")
        self.assertEqual(name["kind"], "text")
        self.assertEqual(name["component"], "ProfileHeader")
        self.assertEqual(name["text"]["font"]["size"], 22)
        self.assertEqual(name["text"]["font"]["weight"], "Bold")
        self.assertEqual(name["frame"][2] > 0, True)

    def test_query_gaps_in_stack_and_neighbours(self):
        name = self.query("--text", "Anna Petrova")
        # The name sits in a VStack(spacing: 4) with the handle under it; the avatar is 14 pt to the left
        # (ProfileHeader's HStack(spacing: 14)).
        self.assertEqual(name["stackGaps"]["axis"], "vertical")
        self.assertEqual(name["stackGaps"]["after"], 4)
        self.assertEqual(name["neighbours"]["left"]["gap"], 14)
        handle = self.query("--text", "@anna.designs")
        self.assertEqual(handle["neighbours"]["above"]["gap"], 4)
        self.assertEqual(handle["neighbours"]["above"]["node"], name["node"])

    def test_measure_between_two_elements(self):
        m = self.measure("text:Anna Petrova", "text:@anna.designs")
        self.assertEqual(m["distance"]["relation"], "apart")
        a, b = m["a"]["frame"], m["b"]["frame"]
        self.assertAlmostEqual(m["distance"]["vertical"], b[1] - (a[1] + a[3]), places=2)
        self.assertEqual(m["distance"]["vertical"], 4)  # VStack(spacing: 4), as the Spacing overlay shows

    def test_measure_takes_option_selectors(self):
        m = json.loads(li("measure", "--text", "Anna Petrova", "--dir", FIXTURE, "--json"))
        self.assertEqual(m["distance"]["relation"], "inside")
        self.assertEqual(m["a"]["name"], self.measure("text:Anna Petrova")["a"]["name"])

    def test_type_selector_ignores_generic_arguments(self):
        # ProfileHeader's HStack has AvatarView among its generic arguments; type:AvatarView must not pick it.
        m = self.query("--type", "AvatarView")
        self.assertEqual(m["kind"], "component")

    def test_measure_avatar_to_name_is_the_stack_spacing(self):
        cap = json.load(open(os.path.join(FIXTURE, "capture.json")))
        nodes = {n["id"]: n for n in cap["nodes"]}
        header = next(n for n in cap["nodes"] if n.get("kind") == "component" and n.get("title") == "ProfileHeader")
        row = next(n for n in cap["nodes"] if n.get("parent") is not None and n.get("stack", {}).get("axis") == "horizontal"
                   and self.is_below(nodes, n, header["id"]))
        self.assertEqual(row["stack"]["spacing"], 14)
        self.assertEqual(row["stack"]["gaps"][0], 14)
        children = sorted([n for n in cap["nodes"] if n.get("parent") == row["id"] and n.get("frame")], key=lambda n: n["frame"][0])
        m = self.measure("node:%d" % children[0]["id"], "node:%d" % children[1]["id"])
        self.assertEqual(m["distance"]["horizontal"], 14)

    def test_measure_one_element_against_its_container(self):
        m = self.measure("text:Anna Petrova")
        self.assertEqual(m["distance"]["relation"], "inside")
        self.assertEqual(m["b"]["name"].split(" ")[0], "ProfileHeader")
        a, b = m["a"]["frame"], m["b"]["frame"]
        self.assertAlmostEqual(m["distance"]["left"], a[0] - b[0], places=2)
        self.assertAlmostEqual(m["distance"]["top"], a[1] - b[1], places=2)

    def test_missing_element_fails_clearly(self):
        p = subprocess.run([sys.executable, LI, "query", "--text", "No such text", "--dir", FIXTURE],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("nothing matches", p.stderr)

    def test_bad_number_is_a_usage_error(self):
        p = subprocess.run([sys.executable, LI, "query", "--text", "Posts", "--index", "x", "--dir", FIXTURE],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertNotIn("Traceback", p.stderr)

    @staticmethod
    def is_below(nodes, node, ancestor_id):
        p = nodes.get(node.get("parent"))
        while p:
            if p["id"] == ancestor_id:
                return True
            p = nodes.get(p.get("parent"))
        return False


class LiOfflineTests(unittest.TestCase):
    def test_measure_matches_overlay_rules(self):
        sys.path.insert(0, HERE)
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("li_module", LI)
        spec = importlib.util.spec_from_loader("li_module", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        self.assertEqual(mod.measure([0, 0, 10, 10], [24, 0, 10, 10]), {"relation": "apart", "horizontal": 14})
        self.assertEqual(mod.measure([0, 0, 10, 10], [0, 30, 10, 10]), {"relation": "apart", "vertical": 20})
        self.assertEqual(mod.measure([10, 10, 20, 20], [0, 0, 100, 50]),
                         {"relation": "inside", "left": 10, "right": 70, "top": 10, "bottom": 20})
        self.assertEqual(mod.measure([0, 0, 10, 10], [5, 5, 10, 10])["relation"], "overlap")
        self.assertEqual(mod.pt(16.0), "16")
        self.assertEqual(mod.pt(19.666), "19.67")


if __name__ == "__main__":
    unittest.main(verbosity=2)
