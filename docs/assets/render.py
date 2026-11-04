"""Rebuild every image in docs/assets from its HTML source.

    python docs/assets/render.py            # all images
    python docs/assets/render.py speed      # one image

Each HTML file sets its own size on html,body. The PNG is always 1280 px wide: a smaller page is rendered at a
higher device scale, so text stays sharp and every image in the README has the same width.
Bars: every element with data-v gets a width proportional to the largest data-v of its card (class "card"),
the largest bar is 82%. tests/bars.sh checks the result. Needs Chrome, Edge or Chromium (WARMD_BROWSER wins).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WIDTH = 1280
# source html -> png name; proof-*.png are real warmd shot captures and are never rendered
PAGES = {"hero": "social", "demo": "demo", "speed": "speed", "tokens": "tokens", "flow": "flow", "features": "features"}


def browser():
    cands = [os.environ.get("WARMD_BROWSER", "")]
    for base in (os.environ.get("ProgramFiles", r"C:\Program Files"), os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
                 os.environ.get("LOCALAPPDATA", "")):
        cands += [os.path.join(base, r"Google\Chrome\Application\chrome.exe"), os.path.join(base, r"Microsoft\Edge\Application\msedge.exe")]
    cands += [shutil.which(n) or "" for n in ("chrome", "msedge", "chromium", "google-chrome")]
    for c in cands:
        if c and os.path.isfile(c):
            return c
    sys.exit("no Chrome, Edge or Chromium found, set WARMD_BROWSER")


def scale_bars(html):
    out, cards = [], re.split(r'(?=<div class="card)', html)
    for card in cards:
        vals = [float(v) for v in re.findall(r'data-v="([0-9.]+)"', card)]
        if vals:
            top = max(vals)
            card = re.sub(r'data-v="([0-9.]+)" style="width:[0-9.]+%"',
                          lambda m: 'data-v="%s" style="width:%.4f%%"' % (m.group(1), 82.0 * float(m.group(1)) / top), card)
        out.append(card)
    return "".join(out)


def size(html):
    m = re.search(r"html,body\{width:(\d+)px;height:(\d+)px", html)
    if not m:
        sys.exit("html,body{width:..px;height:..px} missing")
    return int(m.group(1)), int(m.group(2))


def render(name, exe):
    src = os.path.join(HERE, name + ".html")
    with open(src, encoding="utf-8") as f:
        html = f.read()
    new = scale_bars(html)
    if new != html:
        with open(src, "w", encoding="utf-8", newline="\n") as f:
            f.write(new)
    w, h = size(new)
    scale = WIDTH / w
    png = os.path.join(HERE, PAGES[name] + ".png")
    with tempfile.TemporaryDirectory() as prof:
        subprocess.run([exe, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run", "--user-data-dir=" + prof,
                        "--force-device-scale-factor=%g" % scale, "--window-size=%d,%d" % (w, h),
                        "--default-background-color=0b0f14ff", "--screenshot=" + png, "file:///" + src.replace("\\", "/")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    print("ok   %s.png %dx%d" % (PAGES[name], round(w * scale), round(h * scale)))


if __name__ == "__main__":
    exe = browser()
    for n in (sys.argv[1:] or PAGES):
        render(n, exe)
