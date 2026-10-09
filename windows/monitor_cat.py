"""AI Monitor Windows entry point.

The release is built with ``--windowed``.  ``--self-test`` therefore returns a
process exit code without requiring a console or opening a window, which lets
the Windows CI runner validate the packaged executable itself.
"""

from __future__ import annotations

import sys


def main() -> int:
    if "--self-test" in sys.argv:
        from aimonitor.selftest import run_self_test

        return 0 if run_self_test() else 1
    if "--ui-smoke" in sys.argv:
        from app import run_ui_smoke

        return 0 if run_ui_smoke() else 1
    if "--version" in sys.argv:
        return 0

    from app import run

    return run()


if __name__ == "__main__":
    raise SystemExit(main())
