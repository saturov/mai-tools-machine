#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import youtube_downloader as yd  # noqa: E402


class QualityPolicyTest(unittest.TestCase):
    def test_strict_format_selector_targets_exact_height(self) -> None:
        selector = yd.build_format_selector(min_height=720, quality_policy="strict")
        self.assertIn("height=720", selector)

    def test_best_effort_format_selector_uses_upper_bound(self) -> None:
        selector = yd.build_format_selector(min_height=1080, quality_policy="best_effort")
        self.assertIn("height<=1080", selector)

    def test_strict_rejects_non_exact_height(self) -> None:
        self.assertFalse(yd.is_quality_acceptable(height=360, min_height=720, quality_policy="strict"))

    def test_strict_accepts_exact_height(self) -> None:
        self.assertTrue(yd.is_quality_acceptable(height=720, min_height=720, quality_policy="strict"))

    def test_best_effort_accepts_lower_height(self) -> None:
        self.assertTrue(yd.is_quality_acceptable(height=360, min_height=720, quality_policy="best_effort"))

    def test_best_effort_rejects_height_above_target(self) -> None:
        self.assertFalse(yd.is_quality_acceptable(height=1080, min_height=720, quality_policy="best_effort"))

    def test_env_defaults_resolution(self) -> None:
        with patch.dict(
            os.environ,
            {
                "YT_COOKIES_FROM_BROWSER": "firefox",
                "YT_TARGET_QUALITY": "1080",
                "YT_QUALITY_POLICY": "best_effort",
            },
            clear=False,
        ):
            self.assertEqual("firefox", yd.resolve_effective_cookies_browser(None))
            self.assertEqual(1080, yd.parse_target_quality(os.getenv("YT_TARGET_QUALITY")))
            self.assertEqual("best_effort", yd.resolve_quality_policy(None))

    def test_target_quality_default_is_720(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(720, yd.resolve_target_quality(None, None))

    def test_target_quality_prefers_cli_over_env(self) -> None:
        with patch.dict(os.environ, {"YT_TARGET_QUALITY": "1080"}, clear=False):
            self.assertEqual(480, yd.resolve_target_quality(480, None))

    def test_target_quality_falls_back_to_legacy_env(self) -> None:
        with patch.dict(os.environ, {"YT_MIN_HEIGHT": "600"}, clear=True):
            self.assertEqual(600, yd.resolve_target_quality(None, None))

    def test_default_cookie_browser_has_fallbacks(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(["chrome", "safari", "firefox"], yd.resolve_effective_cookies_browsers(None))

    def test_explicit_cookie_browser_disables_fallbacks(self) -> None:
        self.assertEqual(["safari"], yd.resolve_effective_cookies_browsers("safari"))

    def test_default_clients_use_auto_mode(self) -> None:
        self.assertEqual([None], yd.resolve_effective_clients(None))

    def test_explicit_clients_are_normalized(self) -> None:
        self.assertEqual(["web", "ios"], yd.resolve_effective_clients([" web ", "", "ios"]))

    def test_attempt_plan_tries_without_cookies_first(self) -> None:
        attempts = yd.build_attempt_plan(
            clients=["web", "ios"], cookie_browsers=["chrome", "firefox"]
        )
        self.assertEqual(("web", "none", None), attempts[0])
        self.assertEqual(("ios", "none", None), attempts[1])
        self.assertEqual(("web", "cookies:chrome", "chrome"), attempts[2])
        self.assertEqual(("ios", "cookies:chrome", "chrome"), attempts[3])

    def test_attempt_plan_without_cookies_has_only_plain_attempts(self) -> None:
        attempts = yd.build_attempt_plan(clients=["web"], cookie_browsers=[])
        self.assertEqual([("web", "none", None)], attempts)


if __name__ == "__main__":
    unittest.main()
