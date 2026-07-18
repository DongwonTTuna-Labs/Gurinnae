"""CLI and compatibility facade for the effective acceptance validator."""
from __future__ import annotations

from pathlib import Path
import sys

SCRIPTS_ROOT = Path(__file__).resolve().parents[1]
if str(SCRIPTS_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_ROOT))

from validation import effective_acceptance_impl as _impl
from validation.effective_acceptance_impl import *  # noqa: F401,F403

# Keep the historical private helper surface available to the validator's
# focused mutation tests while the implementation lives in the split module.
globals().update({name: value for name, value in vars(_impl).items() if name.startswith("_") and not name.startswith("__")})
main = _impl.main


if __name__ == "__main__":
    raise SystemExit(main())
