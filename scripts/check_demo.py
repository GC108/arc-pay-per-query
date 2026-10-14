"""Headless check of the demo page deep link: the page must replay the paid query and render verified rows.
Run via: WRANGLER=1 POST_HOOK='<venv-python> ../scripts/check_demo.py' scripts/e2e.sh local
Uses its own isolated Playwright browser (not any shared MCP browser)."""
import pathlib, sys
from playwright.sync_api import sync_playwright

root = pathlib.Path(__file__).resolve().parent.parent
link = sorted((root / "deployments").glob("deeplink-*.txt"), key=lambda p: p.stat().st_mtime)[-1].read_text().strip()
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    errors = []
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.goto(link, timeout=30000)
    pg.wait_for_selector("#result table", timeout=20000)
    rows = pg.locator("#result table tr").count() - 1
    banner = pg.locator("#result .ok").inner_text()
    pg.screenshot(path=str(root / "deployments" / "demo-screenshot.png"), full_page=True)
    b.close()
ok = rows > 0 and "Verified on-chain" in banner and not errors
print(f"{'PASS' if ok else 'FAIL'}  demo page deep link renders {rows} verified rows; banner: {banner[:90]!r}; js errors: {errors}")
sys.exit(0 if ok else 1)
