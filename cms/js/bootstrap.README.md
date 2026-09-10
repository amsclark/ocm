# bootstrap.min.js — modified build

`cms/js/bootstrap.min.js` is **not** the stock Bootstrap 2.3.2 bundle. It is a
reduced build of it, produced by `tools/build-bootstrap-js.py`.

## Why

The stock 2.3.2 bundle carried seven CVEs (GitHub issues #23 and #27):

| CVE | Plugin | Sink |
| --- | --- | --- |
| CVE-2024-6485  | button    | `data-loading-text` |
| CVE-2019-8331  | tooltip / popover | `data-template` |
| CVE-2018-20676 | tooltip   | `data-viewport` |
| CVE-2018-14042 | popover   | `data-container` |
| CVE-2018-14040 | collapse  | `data-parent` |
| CVE-2018-20677 | affix     | `data-target` |
| CVE-2016-10735 | scrollspy / collapse | `data-target` |

Every one of them is in a plugin this application does not use. Upgrading was
not an option: the CSS in `cms/css/` is Bootstrap 2, whose class names and
markup Bootstrap 3 and 4 do not share, and `data-provide="typeahead"` — which
`cms/templates/default.html` uses — was dropped from Bootstrap in 3.0. A
version bump would have meant restyling the whole application, and even
Bootstrap 3.4.1 does not fix CVE-2024-6485 (fixed in 4.0.0).

So the vulnerable plugins were removed instead of shipped dormant.

## What is kept

Only the three plugins that are actually referenced in this tree:

- **transition** — the `$.support.transition` feature test the others rely on.
- **dropdown** — `data-toggle="dropdown"`, used in `cms/templates/default.html`
  and `cms/subtemplates/home.html`.
- **typeahead** — `data-provide="typeahead"` on the search box in
  `cms/templates/default.html`.

Removed: alert, button, carousel, collapse, modal, tooltip, popover,
scrollspy, tab, affix.

The `nav-tabs` and `alert-*` classes elsewhere in the tree are **CSS only** —
the tabs in `cms/template_plugins/case_tabs.php` and `calendar_tabs.php` are
ordinary server-side links with no `data-toggle="tab"`, and no alert anywhere
carries a `data-dismiss="alert"` close button. Neither needs the JS plugin.

## Hardening applied to the plugins that stayed

Both are marked in the minified source with an `OCM-PATCH` comment.

1. **`OCM-PATCH:selector-only` (dropdown).** `data-target`/`href` was passed
   straight to `jQuery()`, which builds DOM nodes from any string it reads as
   HTML — the same sink as CVE-2018-20677 and CVE-2016-10735. It now resolves
   through `$(document).find()` inside a `try`/`catch`, which is Bootstrap
   3.4.1's own fix; `.find()` only ever parses a selector, never HTML.

   The `try`/`catch` matters for a second reason: `href="#"` yields the
   selector `"#"`, and jQuery 3.7 throws `Syntax error, unrecognized
   expression: #` on that where jQuery 1.10.1 did not. Without the catch,
   every dropdown in the application breaks.

2. **`OCM-PATCH:escape-source` (typeahead).** `highlighter()` interpolated a
   raw source item into a string that `render()` hands to `.html()`. Source
   items are now HTML-escaped first. This application supplies no `source`, so
   the sink was not reachable here, but it should not ship either way.

## Rebuilding

    python3 tools/build-bootstrap-js.py

The script refuses to run unless `cms/js/bootstrap.min.js` is the stock 28,631
byte 2.3.2 bundle, so restore that file from git history first. It verifies
every plugin boundary before slicing and asserts each patch matches exactly
once.

## Licence

Bootstrap 2.3.2 is Apache-2.0 (Copyright 2012 Twitter, Inc.). The licence
header is preserved at the top of the built file. Removing plugins and
patching are permitted modifications; they are noted here and in that header
as the licence requires.

## jQuery

`cms/js/jquery.min.js` is stock, unmodified **jQuery 3.7.1** (issues #22 and
#26). It verifies against jQuery's published SRI digest:

    sha256-/JqT3SQfawRcv/BIHPThkBvs0OEvtFFmqPF/lYI/Cxo=
    sha256 fc9a93dd241f6b045cbff0481cf4e1901becd0e12fb45166a8f17f95823f0b1a
