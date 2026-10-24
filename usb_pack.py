#!/usr/bin/env python3
"""usb-pack.py — pack an internet-in-a-box (kiwix zim) content set onto a USB drive.

Downloads an english-oriented "offline internet" library (wikipedia, wikivoyage,
project gutenberg, stackexchange, iFixit, TED...) sized to fit a budget
(default 28 GiB, safe for a 32 GB drive) and moves it to a mounted usb target.

workflow:
  1. fetch kiwix's master library catalog (download.kiwix.org/library/library_zim.xml)
  2. walk a prioritized wishlist, picking the best-available flavor of each entry
     (mini > nopic > maxi) that fits the remaining budget
  3. download each selected zim (resumable via curl -C -) directly into the
     target dir (or a staging dir), verifying sha256 from the kiwix metalink
  4. write manifest.tsv so you know what's on the drive and where it came from

usage:
  ./usb-pack.py --target /media/john/KINGSTON            # pack it
  ./usb-pack.py --target /mnt/usb --budget-gib 26        # tighter budget
  ./usb-pack.py --list                                   # show the plan, download nothing
"""

import argparse
import hashlib
import io
import zipfile
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

CATALOG_URL = "https://download.kiwix.org/library/library_zim.xml"
DEFAULT_BUDGET_GIB = 28
FREE_MARGIN_BYTES = 512 * 1024 * 1024  # keep half a gig spare on the drive

# kiwix-js browser extension (the viewer we bundle on the drive)
BROWSERS_URL = "https://download.kiwix.org/release/browsers/"
CHROME_CRX_URL = BROWSERS_URL + "chrome/kiwix-chrome_4.4.0.crx"
FIREFOX_XPI_URL = BROWSERS_URL + "firefox/kiwix-firefox_4.4.0.xpi"
CHROME_EXT_DIR = "viewer/kiwix-js-chrome"   # unpacked, load via chrome://extensions
FIREFOX_XPI_REL = "viewer/kiwix-firefox.xpi"  # renamed copy on the drive, load via about:debugging
START_HERE = "START_HERE.html"

# flavor preference when a wishlist entry exists in several cuts
FLAVOR_PREF = ["mini", "nopic", "maxi", ""]

# wishlist: regex matched against catalog book "name" (python re, first match
# wins). each pick is greedy-by-priority: later lines only fill leftover budget.
WISHLIST = [
    r"^wikipedia_en_all(_mini)?$",            # the core: all of wikipedia (text)
    r"^wikipedia_en-simple_all$",             # simple english wikipedia
    r"^wikivoyage_en_all$",                   # travel guide
    r"^gutenberg_en_lcc-(c|g|h|r|u|v)$",      # gutenberg letter cuts (small ones)
    r"^gutenberg_en_lcc-(pn|pq|pz)$",         # fiction cut
    r"^ifixit_en_all$",                       # repair manuals
    r"^unix\.stackexchange\.com_en_all$",     # linux Q&A
    r"^diy\.stackexchange\.com_en_all$",      # home improvement Q&A
    r"^physics\.stackexchange\.com_en_all$",
    r"^electronics\.stackexchange\.com_en_all$",
    r"^stats\.stackexchange\.com_en_all$",
    r"^askubuntu\.com_en_all$",
    r"^math\.stackexchange\.com_en_all$",
    r"^ted_mul_ted-ed$",                      # ted education videos
    r"^wiktionary_en_all$",
    r"^ted_mul_science$",
]


def log(msg):
    print(f"[usb-pack] {msg}", flush=True)


# ---------------------------------------------------------------- catalog ---

def fetch_catalog(cache_path="~/.cache/pi-brain/library_zim.xml"):
    """download (with cache) and parse kiwix's library catalog.

    returns {name: {"size_bytes": int, "meta4_url": str, "title": str}} where
    name is the date-stripped zim filename stem (includes the flavor tag).
    sizes in the catalog xml are KiB.
    """
    cache_path = os.path.expanduser(cache_path)
    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
    if not os.path.exists(cache_path):
        log(f"fetching catalog: {CATALOG_URL}")
        tmp = cache_path + ".part"
        urllib.request.urlretrieve(CATALOG_URL, tmp)
        os.replace(tmp, cache_path)

    books = {}
    for b in ET.parse(cache_path).getroot().findall("book"):
        url = b.get("url", "")
        if not url or not url.endswith(".zim.meta4"):
            continue
        # the flavor lives in the *filename* (wikipedia_en_all_mini_2026-09.zim),
        # not in the name attr — several flavors share one name, so key the catalog
        # by the date-stripped stem.
        stem = url.rsplit("/", 1)[-1][: -len(".zim.meta4")]
        name = re.sub(r"_\d{4}-\d{2}$", "", stem)
        if not name or name in books:
            continue
        books[name] = {
            "size_bytes": int(b.get("size", "0")) * 1024,
            "meta4_url": url,
            "title": b.get("title", ""),
        }
    return books


def catalog_by_root(books):
    """group books by their name minus a trailing flavor tag, e.g.
    wikipedia_en_all_mini -> wikipedia_en_all."""
    by_root = {}
    for name, meta in books.items():
        root = re.sub(r"_(mini|nopic|maxi)$", "", name)
        by_root.setdefault(root, {})[name] = meta
    return by_root


# -------------------------------------------------------------- selection ---

def pick_best_variant(by_root, root, remaining_bytes):
    """choose the flavor of `root` we prefer that fits in remaining_bytes."""
    variants = by_root.get(root)
    if not variants:
        return None, 0
    for flavor in FLAVOR_PREF:
        name = f"{root}_{flavor}" if flavor else root
        meta = variants.get(name)
        if meta and meta["size_bytes"] <= remaining_bytes:
            return meta, meta["size_bytes"]
    return None, 0


def select_pack(books, budget_bytes, wishlist=WISHLIST):
    """walk the wishlist in priority order, grabbing what fits.

    returns (selected list of (name, meta), total_bytes, skipped list of name-reasons)
    """
    by_root = catalog_by_root(books)
    selected, total, skipped = [], 0, []
    for pattern in wishlist:
        rx = re.compile(pattern)
        match = next((root for root in by_root if rx.fullmatch(root)), None)
        if not match:
            skipped.append((pattern, "not in catalog"))
            continue
        meta, size = pick_best_variant(by_root, match, budget_bytes - total)
        if meta is None:
            skipped.append((pattern, "over remaining budget"))
            continue
        variant = meta["meta4_url"].rsplit("/", 1)[-1][:-len(".zim.meta4")]
        selected.append((variant, meta))
        total += size
    return selected, total, skipped


def plan_report(selected, total, budget_bytes):
    lines = ["planned pack (%.2f GiB of %.2f GiB budget):" % (total / 2**30, budget_bytes / 2**30)]
    for name, meta in selected:
        lines.append(f"  {meta['size_bytes'] / 2**30:8.2f} GiB  {name:<45s} {meta['title'][:40]}")
    return "\n".join(lines)


# ------------------------------------------------------------- filesystem ---

def check_target(target):
    if not os.path.ismount(target):
        raise SystemExit(f"error: {target} is not a mount point (mount the usb drive first)")
    if not os.path.isdir(target):
        raise SystemExit(f"error: {target} is not a directory")
    return shutil.disk_usage(target)


def mount_device(target):
    """best-effort resolve the block device backing a mountpoint."""
    try:
        out = subprocess.run(["findmnt", "-nro", "SOURCE", target],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip()
    except Exception:
        return "?"


def usb_or_warn(target):
    dev = mount_device(target)
    base = dev and dev.replace("/dev/", "").split("1")[0].rstrip("0123456789")
    removable = None
    if base:
        try:
            with open(f"/sys/class/block/{base}/removable") as f:
                removable = f.read().strip()
        except OSError:
            pass
    if removable == "0":
        log(f"warning: {target} ({dev}) does not look like a removable drive")


def free_after_existing(target, plan_bytes):
    """confirm the drive can hold plan_bytes plus whatever is already on it,
    keeping a small margin."""
    usage = shutil.disk_usage(target)
    spare = usage.free - plan_bytes - FREE_MARGIN_BYTES
    if spare < 0:
        raise SystemExit(
            f"error: not enough free space on {target}: "
            f"free={usage.free/2**30:.2f}GiB, need={(plan_bytes+FREE_MARGIN_BYTES)/2**30:.2f}GiB")
    log(f"space check ok: {usage.free/2**30:.2f} GiB free, pack needs {(plan_bytes)/2**30:.2f} GiB")


# -------------------------------------------------------------- kiwix-js viewer ---

def crx_zip_offset(data):
    """a crx3 file is a 12-byte header + signing data + the actual zip payload.
    the zip always starts with the PK signature, so find it."""
    off = data.find(b"PK\x03\x04")
    return None if off == -1 else off


def unpack_crx(crx_url, dest_dir, payload_zip=None):
    """download the kiwix-js chrome extension and unpack it into dest_dir/chrome
    as a loadable "load unpacked" extension.

    payload_zip lets tests inject the zip bytes (skips the network).
    returns the unpacked extension directory.
    """
    if payload_zip is None:
        log(f"downloading chrome extension: {crx_url}")
        with urllib.request.urlopen(crx_url, timeout=120) as r:
            data = r.read()
    else:
        data = payload_zip.read()
    off = crx_zip_offset(data)
    chrome_dir = os.path.join(dest_dir, "chrome")
    os.makedirs(chrome_dir, exist_ok=True)
    if off is None:
        raise SystemExit(f"error: no zip payload found in {crx_url}")
    buf = io.BytesIO(data[off:])
    try:
        with zipfile.ZipFile(buf) as z:
            z.extractall(chrome_dir)
    except zipfile.BadZipFile:
        # shouldn't happen with a real crx; keep the raw payload around for forensics
        with open(os.path.join(chrome_dir, "payload.bin"), "wb") as f:
            f.write(data[off:])
        log("warning: crx zip payload not extractable; saved raw bytes")
    log(f"chrome viewer unpacked to {chrome_dir}")
    return chrome_dir


def fetch_firefox_xpi(dest_dir, payload=None):
    """drop the firefox .xpi onto the drive so firefox users can load it via
    about:debugging. returns the path."""
    out = os.path.join(dest_dir, FIREFOX_XPI_REL)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if payload is None:
        log(f"downloading firefox extension: {FIREFOX_XPI_URL}")
        urllib.request.urlretrieve(FIREFOX_XPI_URL, out)
    else:
        with open(out, "wb") as f:
            f.write(payload.read())
    log(f"firefox viewer saved to {out}")
    return out


def build_start_here_page(manifest_rows, chrome_dir=CHROME_EXT_DIR, firefox_xpi=FIREFOX_XPI_REL):
    """the little offline landing page that greets whoever plugs the drive in
    and walks them through opening the zims."""
    rows = "\n".join(
        f"      <tr><td>{title}</td><td>{file}</td><td>{size_bytes / 2**30:.2f} GiB</td></tr>"
        for (_name, file, size_bytes, _source, title) in manifest_rows
    )
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Internet-in-a-Box — start here</title>
<style>body{{font-family:sans-serif;max-width:60em;margin:2em auto;line-height:1.5}}
table{{border-collapse:collapse}}td,th{{border:1px solid #999;padding:.3em .8em;text-align:left}}</style></head>
<body>
<h1>📦 internet-in-a-box</h1>
<p>this drive carries offline copies of wikipedia and friends as <b>zim archives</b>.
they don't open by double-click — you need the free <a href="https://kiwix.org">kiwix</a> reader.
this page was made while the drive was packed; everything below works with zero internet.</p>

<h2>chrome / edge / brave (recommended)</h2>
<ol>
  <li>open <code>chrome://extensions</code></li>
  <li>turn on <b>developer mode</b> (toggle, top-right)</li>
  <li>click <b>Load unpacked</b> and pick this folder on the drive:
      <code>{chrome_dir}</code></li>
  <li>open the kiwix extension, click <b>browse</b> / <b>open zim from file</b> and
      pick any <code>.zim</code> listed below. if zim files grey out, enable
      <b>Allow access to file URLs</b> for kiwix on the extensions page.</li>
</ol>

<h2>firefox</h2>
<ol>
  <li>open <code>about:debugging#/runtime/this-firefox</code></li>
  <li><b>load temporary add-on...</b> → pick <code>{firefox_xpi}</code> on this drive.
      (firefox unloads it on restart; repeat after a reboot.)</li>
</ol>

<h2>other options</h2>
<p>a desktop kiwix app (kiwix-desktop) also reads these files, and the
<b>Kiwix JS</b> pwa at <a href="https://pwa.kiwix.org">pwa.kiwix.org</a> works in
any modern browser.</p>

<h2>what's on this drive</h2>
<table>
  <tr><th>title</th><th>file</th><th>size</th></tr>
{rows}
</table>
</body></html>"""


def pack_viewer(target, chrome_dir=CHROME_EXT_DIR, firefox_rel=FIREFOX_XPI_REL):
    """bundle kiwix-js (chrome unpacked + firefox xpi) + a START_HERE.html on the drive."""
    unpack_crx(CHROME_CRX_URL, os.path.join(target, "viewer"))
    fetch_firefox_xpi(target)
    return os.path.join(target, chrome_dir), os.path.join(target, firefox_rel)


# -------------------------------------------------------------- downloads ---

def resolve_zim_url(meta4_url):
    """the direct file sits next to the metalink, minus the .meta4 suffix."""
    return meta4_url[: -len(".meta4")]


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def metalink_sha256(meta4_url, timeout=60):
    try:
        with urllib.request.urlopen(meta4_url, timeout=timeout) as r:
            data = r.read().decode("utf-8", "replace")
        m = re.search(r'<hash type="sha256">([0-9a-fA-F]{64})<', data)
        return m.group(1).lower() if m else None
    except Exception as exc:
        log(f"warning: could not fetch metalink for hash ({exc}); skipping verify")
        return None


def download_zim(meta, dest_dir, verify=True, resume=True):
    """curl the zim (resumable), sha256-verify from the metalink, return path."""
    url = resolve_zim_url(meta["meta4_url"])
    filename = url.rsplit("/", 1)[-1]
    final_path = os.path.join(dest_dir, filename)
    partial_path = os.path.join(dest_dir, filename + ".part")

    if os.path.exists(final_path) and os.path.getsize(final_path) > 0:
        log(f"already have {filename}")
        return final_path

    want_hash = metalink_sha256(meta["meta4_url"]) if verify else None
    log(f"downloading {filename} ({meta['size_bytes'] / 2**30:.2f} GiB)")
    cmd = ["curl", "-fL", "--retry", "5", "-o", partial_path, url]
    if resume:
        cmd[cmd.index("-o"):cmd.index("-o")] = ["-C", "-"]
    r = subprocess.run(cmd)
    if r.returncode != 0:
        raise SystemExit(f"error: curl failed ({r.returncode}) for {url}")

    if want_hash:
        actual = sha256_of(partial_path)
        if actual != want_hash:
            os.remove(partial_path)
            raise SystemExit(f"error: sha256 mismatch for {filename} (got {actual})")
        log(f"sha256 ok: {filename}")
    else:
        actual_size = os.path.getsize(partial_path)
        if actual_size < meta["size_bytes"] * 0.9:
            os.remove(partial_path)
            raise SystemExit(f"error: {filename} suspiciously small ({actual_size} bytes)")

    os.replace(partial_path, final_path)
    return final_path


# ------------------------------------------------------------------- main ---

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--target", help="mountpoint of the usb drive")
    p.add_argument("--budget-gib", type=float, default=DEFAULT_BUDGET_GIB)
    p.add_argument("--stage-dir", help="download here first, then move to target "
                                       "(default: download straight to target)")
    p.add_argument("--list", action="store_true", help="show the plan only")
    p.add_argument("--no-verify", action="store_true", help="skip sha256 verification")
    args = p.parse_args(argv)

    budget = int(args.budget_gib * 2**30)
    books = fetch_catalog()
    selected, total, skipped = select_pack(books, budget)
    print(plan_report(selected, total, budget))
    for pattern, reason in skipped:
        log(f"skipped {pattern}: {reason}")
    if not selected:
        raise SystemExit("error: nothing selectable under this budget")

    if args.list:
        return 0
    if not args.target:
        p.error("--target is required unless --list")

    target = args.target
    check_target(target)
    usb_or_warn(target)
    free_after_existing(target, total)
    dest = args.stage_dir or target
    if args.stage_dir:
        os.makedirs(dest, exist_ok=True)
        if shutil.disk_usage(dest).free < total + FREE_MARGIN_BYTES:
            raise SystemExit(f"error: staging dir {dest} lacks {total/2**30:.2f} GiB of space")

    viewer_dirs = pack_viewer(target)

    manifest = []
    for name, meta in selected:
        path = download_zim(meta, dest, verify=not args.no_verify)
        if args.stage_dir:
            final = os.path.join(target, os.path.basename(path))
            if os.path.exists(final) and os.path.getsize(final) == os.path.getsize(path):
                os.remove(path)
            else:
                shutil.move(path, target)
            path = final
        manifest.append((name, os.path.basename(path), meta["size_bytes"], meta["meta4_url"], meta["title"]))

    manifest_path = os.path.join(target, "manifest.tsv")
    with open(manifest_path, "w") as f:
        f.write("name\tfile\tsize_bytes\tsource\ttitle\n")
        for row in manifest:
            f.write("\t".join(str(x) for x in row) + "\n")
    log(f"wrote {manifest_path}")
    chrome_dir, firefox_xpi = viewer_dirs
    with open(os.path.join(target, START_HERE), "w") as f:
        f.write(build_start_here_page(manifest, chrome_dir, firefox_xpi))
    log(f"wrote {START_HERE} — open it on any computer and follow the viewer install steps")
    log(f"done — packed {total/2**30:.2f} GiB of offline internet onto {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
