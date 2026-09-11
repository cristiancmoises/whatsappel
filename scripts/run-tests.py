#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Run unittest with machine-readable, skip-aware evidence (0 PASS, 1 FAIL, 2 PARTIAL)."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import sys
import time
import unittest


class EvidenceResult(unittest.TextTestResult):
    """Count observed successes directly; subtest failures are not extra passes."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.successes = []
        self.timings = []
        self.started = 0.0

    def startTest(self, test):
        self.started = time.monotonic()
        super().startTest(test)

    def stopTest(self, test):
        self.timings.append({"test": test.id(), "seconds": time.monotonic() - self.started})
        super().stopTest(test)

    def addSuccess(self, test):
        self.successes.append(test.id())
        super().addSuccess(test)


def run_tests(source: Path, pattern: str) -> dict:
    suite = unittest.TestLoader().discover(str(source / "tests"), pattern=pattern)
    discovered = suite.countTestCases()
    result = unittest.TextTestRunner(verbosity=2, resultclass=EvidenceResult).run(suite)
    failure = (not result.wasSuccessful()) or discovered == 0
    incomplete = bool(result.skipped or result.expectedFailures or result.testsRun == 0)
    status = "FAIL" if failure else "PARTIAL" if incomplete else "PASS"
    return {"schema": 1, "status": status, "discovered": discovered,
            "run": result.testsRun, "passed": len(result.successes),
            "failures": len(result.failures), "errors": len(result.errors),
            "skipped": len(result.skipped), "expected_failures": len(result.expectedFailures),
            "unexpected_successes": len(result.unexpectedSuccesses),
            "successful_tests": result.successes,
            "skips": [{"test": t.id(), "reason": reason} for t, reason in result.skipped],
            "failed_tests": [t.id() for t, _ in result.failures],
            "error_tests": [t.id() for t, _ in result.errors],
            "durations": sorted(result.timings, key=lambda item: item["seconds"], reverse=True)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path.cwd())
    parser.add_argument("--pattern", default="test_*.py")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args(argv)
    # Reserve exclusively before importing any tests, so old evidence is not overwritten.
    fd = os.open(args.report, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        report = run_tests(args.source.resolve(), args.pattern)
        json.dump(report, output, indent=2, ensure_ascii=True)
        output.write("\n")
    return {"PASS": 0, "FAIL": 1, "PARTIAL": 2}[report["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
