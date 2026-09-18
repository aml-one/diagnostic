"""Opaque full-bleed Android launcher plate from the light Diagnostic master.

HyperOS paints transparent corner padding white. Reuses the family
opaque_android_launcher helper from MessageMe.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
FAMILY = (
    REPO.parent
    / "messageme"
    / "scripts"
    / "generate-app-icon-family.py"
)
LIGHT = REPO / "assets" / "branding" / "app_icon_light.png"
OUT = REPO / "assets" / "branding" / "app_icon_launcher.png"


def load_family():
    spec = importlib.util.spec_from_file_location("app_icon_family", FAMILY)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {FAMILY}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    if not FAMILY.is_file():
        print(f"missing family generator: {FAMILY}", file=sys.stderr)
        return 1
    if not LIGHT.is_file():
        print(f"missing light master: {LIGHT}", file=sys.stderr)
        return 1
    family = load_family()
    from PIL import Image

    master = Image.open(LIGHT)
    plate = family.opaque_android_launcher(master)
    family.save_png(plate, OUT)
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
