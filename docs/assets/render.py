"""Rebuild every image in docs/assets from its HTML source.

    python docs/assets/render.py            # all images
    python docs/assets/render.py speed      # one source

All sources share theme.css (light by default, html.dark for the dark variant). README images are rendered twice,
<name>-light.png and <name>-dark.png, for a <picture> that follows prefers-color-scheme. Each source is 800 CSS px
wide and rendered at device scale 2, so every README image is 1600 px wide and crisp at 2x when shown at width 800.
social.png is 1280x640 for the GitHub social preview, light only.
Bars: every element with data-v gets a width proportional to the largest data-v of its card (class "card"),
the largest bar is 82%. tests/bars.sh checks the result.
With Pillow installed the PNG is reduced to a 256 colour palette, which keeps the flat art sharp and the file small.
Needs Chrome, Edge or Chromium (WARMD_BROWSER wins). hero.log holds the raw warmd session shown in hero.html.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# source html -> (png base name, themes, output width); proof-*.png are real warmd shot captures and are never rendered
PAGES = {
    "hero": ("hero", ("light", "dark"), 1600),
    "auto": ("auto", ("light", "dark"), 1600),
    "speed": ("speed", ("light", "dark"), 1600),
    "tokens": ("tokens", ("light", "dark"), 1600),
    "social": ("social", ("light",), 1280),
}
BG = {"light": "f6f1e8ff", "dark": "14110eff"}


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


def shrink(png):
    try:
        from PIL import Image
    except ImportError:
        return
    with Image.open(png) as im:
        q = im.convert("RGB").quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    q.save(png, optimize=True)


def render(name, exe):
    src = os.path.join(HERE, name + ".html")
    with open(src, encoding="utf-8") as f:
        html = f.read()
    new = scale_bars(html)
    if new != html:
        with open(src, "w", encoding="utf-8", newline="\n") as f:
            f.write(new)
    base, themes, width = PAGES[name]
    w, h = size(new)
    scale = width / w
    for theme in themes:
        png = os.path.join(HERE, base + (".png" if len(themes) == 1 else "-%s.png" % theme))
        # the themed copy sits next to the source so theme.css resolves, and is removed right after
        fd, tmp = tempfile.mkstemp(suffix=".html", prefix=".render-", dir=HERE)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new.replace("<html>", '<html class="%s">' % theme, 1))
        try:
            with tempfile.TemporaryDirectory() as prof:
                subprocess.run([exe, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run", "--user-data-dir=" + prof,
                                "--force-device-scale-factor=%g" % scale, "--window-size=%d,%d" % (w, h),
                                "--default-background-color=" + BG[theme], "--screenshot=" + png, "file:///" + tmp.replace("\\", "/")],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        finally:
            os.remove(tmp)
        shrink(png)
        print("ok   %s %dx%d %d KB" % (os.path.basename(png), round(w * scale), round(h * scale), os.path.getsize(png) // 1024))


if __name__ == "__main__":
    exe = browser()
    for n in (sys.argv[1:] or PAGES):
        render(n, exe)
