#!/usr/bin/env python3
"""Render the final static design reference without the prototype switcher."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

from playwright.async_api import async_playwright


ROOT = Path(__file__).resolve().parents[1]
PROTOTYPE = ROOT / "specs/ui/final-reference"
OUTPUT = ROOT / "verification/final-reference"

CASES = [
    ("home", 1440, 1050, "desktop-home.png"),
    ("case", 1440, 1050, "desktop-case.png"),
    ("search", 1440, 1050, "desktop-search.png"),
    ("agency", 1440, 1050, "desktop-agency.png"),
    ("workspace", 1440, 1050, "desktop-workspace.png"),
    ("review", 1440, 1050, "desktop-review.png"),
    ("response", 1440, 1050, "desktop-response.png"),
    ("case", 390, 844, "mobile-case.png"),
    ("response", 390, 844, "mobile-response.png"),
    ("workspace", 820, 1050, "tablet-workspace.png"),
]


def document_for(view: str) -> str:
    html = (PROTOTYPE / "index.html").read_text(encoding="utf-8")
    css = (PROTOTYPE / "styles.css").read_text(encoding="utf-8")
    js = (PROTOTYPE / "app.js").read_text(encoding="utf-8")
    js = js.replace(
        "const view = params.get('view') || 'home';",
        f"const view = {view!r};",
    )
    html = html.replace(
        '<link rel="stylesheet" href="./styles.css">',
        f"<style>{css}\n.prototype-switcher{{display:none!important}}</style>",
    )
    html = html.replace(
        '<script src="./app.js"></script>',
        f"<script>{js}</script>",
    )
    return html


async def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    results = []

    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(headless=True, executable_path='/usr/bin/chromium', args=['--no-sandbox'])
        try:
            for view, width, height, filename in CASES:
                page_errors: list[str] = []
                page = await browser.new_page(
                    viewport={"width": width, "height": height},
                    device_scale_factor=1,
                    color_scheme="light",
                    locale="ko-KR",
                )
                page.on("pageerror", lambda error: page_errors.append(str(error)))
                await page.set_content(document_for(view), wait_until="load")
                await page.emulate_media(reduced_motion="reduce")
                await page.evaluate("document.fonts && document.fonts.ready")
                await page.wait_for_timeout(120)
                output = OUTPUT / filename
                await page.screenshot(path=output, full_page=False)
                results.append(
                    {
                        "view": view,
                        "viewport": f"{width}x{height}",
                        "file": str(output.relative_to(ROOT)),
                        "bytes": output.stat().st_size,
                        "page_errors": page_errors,
                    }
                )
                await page.close()
        finally:
            await browser.close()

    (OUTPUT / "render-results.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
