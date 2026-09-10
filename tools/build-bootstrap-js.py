#!/usr/bin/env python3
"""Rebuild cms/js/bootstrap.min.js from the bundled Bootstrap 2.3.2 sources,
keeping only the plugins this application actually uses, and applying two
targeted hardening patches to the plugins that are kept.

Run from the repo root.
"""
import re
import sys

SRC = "cms/js/bootstrap.min.js"

# Byte offsets of each plugin IIFE in the stock Bootstrap 2.3.2 bundle.
BLOCKS = [
    ("header",      0,      117),
    ("transition",  117,    484),
    ("alert",       484,    1322),
    ("button",      1322,   2403),
    ("carousel",    2403,   5512),
    ("collapse",    5512,   7779),
    ("dropdown",    7779,   9533),
    ("modal",       9533,   12917),
    ("tooltip",     12917,  18079),
    ("popover",     18079,  19398),
    ("scrollspy",   19398,  21370),
    ("tab",         21370,  22694),
    ("typeahead",   22694,  27182),
    ("affix",       27182,  28631),
]

KEEP = ["transition", "dropdown", "typeahead"]

STOCK_LEN = 28631
STOCK_SHA = None  # informational only

HEADER = """/*!
* Bootstrap.js by @fat & @mdo
* Copyright 2012 Twitter, Inc.
* http://www.apache.org/licenses/LICENSE-2.0.txt
*
* MODIFIED BUILD -- see cms/js/bootstrap.README.md
*
* Derived from the stock Bootstrap 2.3.2 bundle. Reduced to the three plugins
* this application uses (transition, dropdown, typeahead). The plugins that
* carried CVE-2016-10735, CVE-2018-14040, CVE-2018-14042, CVE-2018-20676,
* CVE-2018-20677, CVE-2019-8331 and CVE-2024-6485 -- alert, button, carousel,
* collapse, modal, tooltip, popover, scrollspy, tab and affix -- are not used
* anywhere in this tree and have been removed rather than shipped dormant.
*
* Two hardening patches are applied to the plugins that remain; both are
* marked with an OCM-PATCH comment below.
*/
"""


def patch_dropdown(seg):
    """data-target / href is handed straight to jQuery as a selector, and
    jQuery builds DOM nodes from any string it reads as HTML -- the same sink
    as CVE-2018-20677 (affix data-target) and CVE-2016-10735.

    Use Bootstrap 3.4.1's fix: resolve through $(document).find(), which only
    ever parses a selector and never HTML, inside a try/catch. The catch also
    restores jQuery 1.x behaviour for href="#", which yields the selector "#";
    jQuery 3.7 throws "Syntax error, unrecognized expression: #" on that, where
    1.10.1 did not. Either way `if (!r || !r.length) r = t.parent()` applies."""
    old = 'r=n&&e(n)'
    new = ('r=n&&function(){/*OCM-PATCH:selector-only*/'
           'try{return e(document).find(n)}catch(o){return null}}()')
    if seg.count(old) != 1:
        sys.exit("dropdown patch: expected exactly 1 match for %r, got %d"
                 % (old, seg.count(old)))
    return seg.replace(old, new)


def patch_typeahead(seg):
    """highlighter() interpolates a raw source item into a string that render()
    then passes to .html(). Escape the item first so a source can never inject
    markup."""
    old = ('highlighter:function(e){var t=this.query.replace('
           '/[\\-\\[\\]{}()*+?.,\\\\\\^$|#\\s]/g,"\\\\$&")')
    new = ('highlighter:function(e){/*OCM-PATCH:escape-source*/'
           'e=String(e).replace(/&/g,"&amp;").replace(/</g,"&lt;")'
           '.replace(/>/g,"&gt;").replace(/"/g,"&quot;");'
           'var t=this.query.replace(/[\\-\\[\\]{}()*+?.,\\\\\\^$|#\\s]/g,"\\\\$&")')
    if seg.count(old) != 1:
        sys.exit("typeahead patch: expected exactly 1 match, got %d"
                 % seg.count(old))
    return seg.replace(old, new)


PATCHES = {"dropdown": patch_dropdown, "typeahead": patch_typeahead}


def main():
    src = open(SRC, encoding="utf-8").read()
    if len(src) != STOCK_LEN:
        sys.exit("refusing to run: %s is %d bytes, expected the stock 2.3.2 "
                 "bundle at %d bytes" % (SRC, len(src), STOCK_LEN))

    segs = {name: src[a:b] for name, a, b in BLOCKS}

    # Every plugin block is a comma-joined IIFE; verify before slicing.
    for name, a, b in BLOCKS:
        if name == "header":
            continue
        seg = segs[name]
        if not seg.startswith("!function(e){"):
            sys.exit("block %s does not start with an IIFE" % name)
        if not (seg.endswith("}(window.jQuery),") or
                seg.endswith("}(window.jQuery);")):
            sys.exit("block %s does not end at an IIFE boundary" % name)

    out = [HEADER]
    for name in KEEP:
        seg = segs[name]
        if name in PATCHES:
            seg = PATCHES[name](seg)
        out.append(seg)

    body = "".join(out)
    # The last kept block still carries the sequence comma; terminate it.
    assert body.endswith("}(window.jQuery),"), body[-40:]
    body = body[:-1] + ";\n"

    open(SRC, "w", encoding="utf-8").write(body)
    print("wrote %s: %d bytes (was %d), kept %s"
          % (SRC, len(body), len(src), ", ".join(KEEP)))


if __name__ == "__main__":
    main()
