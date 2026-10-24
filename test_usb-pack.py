#!/usr/bin/env python3
"""test_usb_pack.py — unit tests for usb_pack.py (no network needed)."""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import usb_pack  # noqa: E402

fail = 0


def check(cond, label):
    global fail
    print(("ok: " if cond else "FAIL: ") + label)
    if not cond:
        fail = 1


GIB = 2**30


def fake_book(kib, name="t"):
    # sizes are in catalog KiB units; scale kib*1024*1024 so "13000" reads as ~12.7 GiB
    # variant name == catalog key, mirroring the real catalog where filename IS the name
    return {"size_bytes": kib * 1024 * 1024, "meta4_url": f"https://lb.download.kiwix.org/zim/x/{name}.zim.meta4", "title": name}


fake_catalog = {
    "wikipedia_en_all_mini": fake_book(13000, "wikipedia_en_all_mini"),
    "wikipedia_en_all_maxi": fake_book(30000, "wikipedia_en_all_maxi"),
    "wikipedia_en-simple_all_mini": fake_book(500, "wikipedia_en-simple_all_mini"),
    "wikivoyage_en_all": fake_book(1000, "wikivoyage_en_all"),
    "gutenberg_en_lcc-c": fake_book(1200, "gutenberg_en_lcc-c"),
    "gutenberg_en_lcc-h": fake_book(4200, "gutenberg_en_lcc-h"),
    "gutenberg_en_lcc-x": fake_book(900, "gutenberg_en_lcc-x"),
    "unix.stackexchange.com_en_all": fake_book(1200, "unix.stackexchange.com_en_all"),
    "electronics.stackexchange.com_en_all": fake_book(4000, "electronics.stackexchange.com_en_all"),
    "ted_mul_ted-ed": fake_book(5900, "ted_mul_ted-ed"),
    "wiktionary_en_all": fake_book(2500, "wiktionary_en_all"),
}

# --- select_pack: priority order + budget clamping --------------------------
sel, total, skipped = usb_pack.select_pack(fake_catalog, 29 * GIB)
names = [n for n, _ in sel]
check(names[0] == "wikipedia_en_all_mini", "core wikipedia picked as mini")
check("wikipedia_en-simple_all_mini" in names, "simple english picked (mini flavor wins)")
check("gutenberg_en_lcc-c" in names, "small gutenberg cut included")
check("gutenberg_en_lcc-x" not in names, "gutenberg cut not in wishlist excluded")
check("electronics.stackexchange.com_en_all" in names, "electronics fits")
check("wiktionary_en_all" in names, "wiktionary fills leftover budget")
check(total <= 29 * GIB, f"total {total/GIB:.2f} GiB within budget")

sel2, total2, skipped2 = usb_pack.select_pack(fake_catalog, 14 * GIB)
names2 = [n for n, _ in sel2]
check(names2[0] == "wikipedia_en_all_mini", "tiny budget still gets core wikipedia")
check("electronics.stackexchange.com_en_all" not in names2, "big entries skipped when over budget")
check(total2 <= 14 * GIB, f"tiny budget respected ({total2/GIB:.2f} GiB)")
skipped_reasons = [r for _, r in skipped2]
check("over remaining budget" in skipped_reasons, "over-budget entries are reported skipped")

sel3, _, skipped3 = usb_pack.select_pack(fake_catalog, 100 * GIB, wishlist=[r"^does_not_exist$"])
check(len(sel3) == 0 and skipped3 and skipped3[0][1] == "not in catalog", "missing catalog entries reported")

# --- flavor preference ------------------------------------------------------
meta, size = usb_pack.pick_best_variant(usb_pack.catalog_by_root(fake_catalog), "wikipedia_en_all", 100 * GIB)
check(meta is not None and "mini" in meta["meta4_url"], "prefers mini flavor first")
meta, _ = usb_pack.pick_best_variant(usb_pack.catalog_by_root(fake_catalog), "wikipedia_en_all", 15 * GIB)
check(meta and "mini" in meta["meta4_url"], "mini still fits at 15 GiB remaining")
meta, _ = usb_pack.pick_best_variant(usb_pack.catalog_by_root(fake_catalog), "wikipedia_en-simple_all", 800 * 1024 * 1024)
check(meta and "mini" in meta["meta4_url"], "falls back to smaller flavor when big one does not fit")
meta, _ = usb_pack.pick_best_variant(usb_pack.catalog_by_root(fake_catalog), "gutenberg_en_lcc-c", 100 * 1024)
check(meta is None, "no variant small enough -> None")

# --- url handling -----------------------------------------------------------
check(usb_pack.resolve_zim_url("https://h/zim/x/w.zim.meta4") == "https://h/zim/x/w.zim", "meta4 stripped from url")

# --- metalink hash parsing (local file via file://) --------------------------
with tempfile.NamedTemporaryFile("w", suffix=".meta4", delete=False) as f:
    f.write('<?xml version="1.0"?><metalink><file name="a.zim"><size>1</size>'
            '<hash type="sha256">ABCD0123abcd0123ABCD0123abcd0123ABCD0123abcd0123ABCD0123abcd0123</hash>'
            '</file></metalink>')
    path = f.name
got = usb_pack.metalink_sha256("file://" + path)
check(got == "abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123", "metalink sha256 parsed+lowercased")
os.unlink(path)

# --- sha256_of ---------------------------------------------------------------
with tempfile.NamedTemporaryFile("wb", delete=False) as f:
    f.write(b"hello world")
check(usb_pack.sha256_of(f.name) == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9", "sha256 correct")
os.unlink(f.name)

# --- download_zim: already-present skip --------------------------------------
with tempfile.TemporaryDirectory() as d:
    final = os.path.join(d, "wiki-mini.zim")
    with open(final, "w") as f:
        f.write("x")
    got = usb_pack.download_zim(fake_book(1, "wiki-mini"), d, verify=False)
    check(got == final, "existing file short-circuits download")

# --- plan report sanity -------------------------------------------------------
rep = usb_pack.plan_report(sel, total, 29 * GIB)
check("planned pack" in rep and "wikipedia_en_all_mini" in rep, "plan report lists selections")

# --- CLI smoke: --list works end to end with a stubbed catalog ----------------
with tempfile.TemporaryDirectory() as d:
    cache = os.path.join(d, "library_zim.xml")
    with open(cache, "w") as f:
        f.write('<library version="20110515"><book id="a" size="13000" title="Wikipedia" '
                'language="eng" name="wikipedia_en_all_mini" '
                'url="https://lb.download.kiwix.org/zim/wikipedia/wikipedia_en_all_mini_2026-09.zim.meta4"/></library>')
    books = usb_pack.fetch_catalog(cache)  # cache exists -> no network fetch
check("wikipedia_en_all_mini" in books and books["wikipedia_en_all_mini"]["size_bytes"] == 13000 * 1024,
      "fetch_catalog parses real-shaped xml from cache")
check(books["wikipedia_en_all_mini"]["meta4_url"].endswith(".zim.meta4"), "catalog keeps meta4 url")

# --- START_HERE prompt page + crx unpack helpers ------------------------------
import io, zipfile
fake_crx = b"Cr24" + b"\x00" * 10 + b"PK\x03\x04inner-zip-payload"
check(usb_pack.crx_zip_offset(fake_crx) == fake_crx.index(b"PK\x03\x04"), "crx_zip_offset finds the zip signature")
check(usb_pack.crx_zip_offset(b"no sig") is None, "crx_zip_offset -> None without signature")
with tempfile.TemporaryDirectory() as d:
    out = usb_pack.unpack_crx("https://example.invalid/x.crx", d, payload_zip=io.BytesIO(fake_crx))
    check(os.path.isdir(out) and out.endswith("chrome"), "unpack_crx extracts to chrome/ dir")
    check(os.path.exists(os.path.join(out, "payload.bin")), "unpack_crx wrote extracted zip payload")
html = usb_pack.build_start_here_page([
    ("wikipedia_en_all_mini", "wikipedia_en_all_mini_2026-09.zim", 13000 * 1024 * 1024, "u", "Wikipedia (mini)")
], chrome_dir="viewer/kiwix-js-chrome", firefox_xpi="viewer/kiwix-firefox_4.4.0.xpi")
for needle in ("Load unpacked", "developer mode", "about:debugging", "wikipedia_en_all_mini_2026-09.zim",
               "chrome://extensions", "Allow access to file URLs"):
    check(needle in html, f"START_HERE page mentions: {needle}")

# --- viewer-only mode: bolt the view layer onto a content-only stick ---------
import argparse

with tempfile.TemporaryDirectory() as target:
    # content-only stick: two zims + a manifest.tsv (one stale row on purpose)
    for zf, mb in (("wikipedia_en_all_mini_2026-09.zim", 700), ("wikivoyage_en_all_2026-09.zim", 100)):
        with open(os.path.join(target, zf), "wb") as f:
            f.write(b"z" * mb)
    with open(os.path.join(target, "manifest.tsv"), "w") as f:
        f.write("name\tfile\tsize_bytes\tsource\ttitle\n")
        f.write("wikipedia_en_all_mini\twikipedia_en_all_mini_2026-09.zim\t%d\tu\tWikipedia (mini)\n" % 700)
        f.write("ghost_en_all\tdeleted_en_all_2026-01.zim\t50\tu\tGhost book\n")

    orig_unpack, orig_fetch, orig_usb, orig_check = (
        usb_pack.unpack_crx, usb_pack.fetch_firefox_xpi, usb_pack.usb_or_warn, usb_pack.check_target)
    unpacked = {}
    def fake_unpack(url, dest_dir, payload_zip=None):
        d = os.path.join(dest_dir, "chrome")
        os.makedirs(d)
        unpacked["url"] = url
        return d
    def fake_fetch(dest_dir, payload=None):
        p = os.path.join(dest_dir, usb_pack.FIREFOX_XPI_REL)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").close()
        return p
    try:
        usb_pack.unpack_crx, usb_pack.fetch_firefox_xpi, usb_pack.usb_or_warn = fake_unpack, fake_fetch, lambda t: None
        usb_pack.check_target = lambda t: None
        rc = usb_pack.main(["--viewer-only", "--target", target])
    finally:
        usb_pack.unpack_crx, usb_pack.fetch_firefox_xpi, usb_pack.usb_or_warn = orig_unpack, orig_fetch, orig_usb
        usb_pack.check_target = orig_check
    check(rc == 0, "viewer-only run exits 0")
    check(os.path.isfile(os.path.join(target, "viewer/chrome/manifest.json")) or
          os.path.isdir(os.path.join(target, "viewer/chrome")), "viewer packed onto drive")
    check(os.path.isfile(os.path.join(target, usb_pack.FIREFOX_XPI_REL)), "firefox xpi on drive")
    sh = open(os.path.join(target, usb_pack.START_HERE)).read()
    check("Wikipedia (mini)" in sh, "START_HERE lists titles from manifest.tsv")
    check("Ghost book" not in sh, "stale manifest row (file gone) dropped")
    check("wikivoyage_en_all_2026-09.zim" in sh, "drive-side zim not in manifest still listed")
    zim_sizes_ok = all(os.path.getsize(os.path.join(target, f)) == s
                       for f, s in (("wikipedia_en_all_mini_2026-09.zim", 700), ("wikivoyage_en_all_2026-09.zim", 100)))
    check(zim_sizes_ok, "viewer-only didn't touch the zim content")

# fallback when there's no manifest at all
with tempfile.TemporaryDirectory() as target:
    with open(os.path.join(target, "only_thing.zim"), "wb") as f:
        f.write(b"z" * 10)
    rows = usb_pack.load_manifest_rows(target)
    check(len(rows) == 1 and rows[0][1] == "only_thing.zim", "manifest fallback: globs zims on drive")

# viewer-only refuses a stick with no zims
with tempfile.TemporaryDirectory() as target:
    os.makedirs(os.path.join(target, "x"))
    orig_check = usb_pack.check_target
    try:
        usb_pack.check_target = lambda t: None
        usb_pack.main(["--viewer-only", "--target", target])
        check(False, "viewer-only rejects zim-less drive")
    except SystemExit as e:
        check("no .zim files found" in str(e), "viewer-only rejects zim-less drive")
    finally:
        usb_pack.check_target = orig_check

# --viewer-only without --target errors
try:
    usb_pack.main(["--viewer-only"])
    check(False, "viewer-only requires --target")
except argparse.ArgumentTypeError:
    pass
except SystemExit:
    pass

# syntax check the whole script
r = subprocess.run([sys.executable, "-m", "py_compile", os.path.join(os.path.dirname(os.path.abspath(__file__)), "usb_pack.py")])
check(r.returncode == 0, "usb_pack.py compiles")

sys.exit(1 if fail else 0)
