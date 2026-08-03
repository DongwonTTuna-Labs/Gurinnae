from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

from scripts import materialize_application


class MaterializeApplicationCliTests(unittest.TestCase):
    def test_help_exits_before_any_materialization(self) -> None:
        stdout = io.StringIO()
        with (
            patch.object(materialize_application, "rust_workspace") as rust_workspace,
            patch.object(materialize_application, "load_yaml") as load_yaml,
            patch.object(materialize_application, "frontend_workspace") as frontend_workspace,
            redirect_stdout(stdout),
            self.assertRaises(SystemExit) as raised,
        ):
            materialize_application.main(["--help"])

        self.assertEqual(raised.exception.code, 0)
        self.assertIn("usage:", stdout.getvalue())
        rust_workspace.assert_not_called()
        load_yaml.assert_not_called()
        frontend_workspace.assert_not_called()

    def test_unknown_argument_exits_before_any_materialization(self) -> None:
        stderr = io.StringIO()
        with (
            patch.object(materialize_application, "rust_workspace") as rust_workspace,
            patch.object(materialize_application, "load_yaml") as load_yaml,
            patch.object(materialize_application, "frontend_workspace") as frontend_workspace,
            redirect_stderr(stderr),
            self.assertRaises(SystemExit) as raised,
        ):
            materialize_application.main(["--unknown-argument"])

        self.assertEqual(raised.exception.code, 2)
        self.assertIn("unrecognized arguments", stderr.getvalue())
        rust_workspace.assert_not_called()
        load_yaml.assert_not_called()
        frontend_workspace.assert_not_called()

    def test_success_reports_the_materialized_screen_count(self) -> None:
        stdout = io.StringIO()
        screens = [{"id": f"PUB-{ordinal:03d}"} for ordinal in range(1, 96)]
        with (
            patch.object(materialize_application, "rust_workspace") as rust_workspace,
            patch.object(
                materialize_application,
                "load_yaml",
                return_value={"screens": screens},
            ) as load_yaml,
            patch.object(materialize_application, "frontend_workspace") as frontend_workspace,
            redirect_stdout(stdout),
        ):
            materialize_application.main([])

        rust_workspace.assert_called_once_with()
        load_yaml.assert_called_once_with("specs/ui/screen-build-manifest.yaml")
        frontend_workspace.assert_called_once_with(screens)
        self.assertEqual(
            stdout.getvalue(),
            "materialized Rust workspace and 95 SvelteKit routes\n",
        )


if __name__ == "__main__":
    unittest.main()
