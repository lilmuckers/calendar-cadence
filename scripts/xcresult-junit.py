#!/usr/bin/env python3
"""Turn an .xcresult bundle's test results into a JUnit XML report.

Usage: scripts/xcresult-junit.py build/ios-tests.xcresult build/ios-junit.xml
Reads `xcrun xcresulttool get test-results tests` (Xcode 16+), so no extra tools are needed on CI.
"""
import json
import subprocess
import sys
from xml.etree import ElementTree as ET


def load(path):
    out = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path, "--format", "json"],
        check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def cases(node, suite=None):
    """Yield (suite, case) for every test case, nested suites joined with '.'."""
    kind = node.get("nodeType")
    if kind == "Test Case":
        yield suite or "Tests", node
        return
    if kind == "Test Suite":
        suite = f"{suite}.{node['name']}" if suite else node["name"]
    for child in node.get("children", []):
        yield from cases(child, suite)


def messages(node):
    for child in node.get("children", []):
        if child.get("nodeType") == "Failure Message":
            yield child.get("name", "")
        yield from messages(child)


def main(src, dst):
    data = load(src)
    suites = {}
    for root in data.get("testNodes", []):
        for suite, case in cases(root):
            suites.setdefault(suite, []).append(case)

    top = ET.Element("testsuites", name="iPhone unit tests")
    totals = {"tests": 0, "failures": 0, "skipped": 0}
    for name, items in sorted(suites.items()):
        el = ET.SubElement(top, "testsuite", name=name)
        counts = {"tests": 0, "failures": 0, "skipped": 0}
        time = 0.0
        for case in items:
            seconds = float(case.get("durationInSeconds") or 0)
            time += seconds
            tc = ET.SubElement(el, "testcase", classname=name, name=case["name"], time=f"{seconds:.3f}")
            counts["tests"] += 1
            result = case.get("result", "")
            if result == "Failed":
                counts["failures"] += 1
                text = "\n".join(messages(case)) or "Failed"
                ET.SubElement(tc, "failure", message=text.splitlines()[0]).text = text
            elif result == "Skipped":
                counts["skipped"] += 1
                ET.SubElement(tc, "skipped")
            elif result == "Expected Failure":
                pass
        for k, v in counts.items():
            el.set(k, str(v))
            totals[k] += v
        el.set("time", f"{time:.3f}")
    for k, v in totals.items():
        top.set(k, str(v))
    ET.ElementTree(top).write(dst, encoding="utf-8", xml_declaration=True)
    print(f"{totals['tests']} tests, {totals['failures']} failed, {totals['skipped']} skipped → {dst}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
