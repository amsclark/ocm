/*
 * Regression test for the bundled JS libraries in cms/js/.
 *
 * Covers the fixes for GitHub issues #22, #23, #26 and #27:
 *   - cms/js/jquery.min.js is stock jQuery 3.7.1
 *   - cms/js/bootstrap.min.js is the reduced Bootstrap 2.3.2 build described
 *     in cms/js/bootstrap.README.md
 *
 * The dropdown cases are not decorative. Bootstrap 2's dropdown turns
 * href="#" into the selector "#", which jQuery 3.7 rejects with a syntax
 * error where jQuery 1.10.1 did not -- so an unguarded jQuery upgrade breaks
 * every dropdown in the application. That is what these assertions catch.
 *
 * Usage:
 *     npm install jsdom      # not vendored; install anywhere on NODE_PATH
 *     node tests/js_libs_test.js
 *
 * Exits non-zero on failure.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const REPO = path.resolve(__dirname, '..');
const JS = path.join(REPO, 'cms', 'js');

let JSDOM;
try {
  ({ JSDOM } = require('jsdom'));
} catch (e) {
  console.error('SKIP: jsdom is not installed. Run `npm install jsdom` first.');
  process.exit(2);
}

// jQuery's published digest for jquery-3.7.1.min.js.
const JQUERY_371_SHA256 =
  'fc9a93dd241f6b045cbff0481cf4e1901becd0e12fb45166a8f17f95823f0b1a';

// Plugins removed from the bundle because they carried the CVEs in #23/#27.
const REMOVED = ['alert', 'button', 'carousel', 'collapse', 'modal', 'tooltip',
                 'popover', 'scrollspy', 'tab', 'affix'];

// Markup taken from cms/templates/default.html and cms/subtemplates/home.html.
const PAGE = `<!doctype html><html><body>
  <div class="btn-group" id="grp">
    <a class="btn btn-inverse dropdown-toggle" id="toggle" data-toggle="dropdown" href="#"><span class="caret"></span></a>
    <ul class="dropdown-menu"><li><a href="/x">Item</a></li></ul>
  </div>
  <div class="btn-group" id="grp2">
    <a class="btn dropdown-toggle" id="toggle2" data-toggle="dropdown" data-target="&lt;img src=x onerror=window.__XSS=1&gt;" href="#"></a>
    <ul class="dropdown-menu"><li><a href="/y">Y</a></li></ul>
  </div>
  <input id="searchinput" name="s" type="text" autocomplete="off" data-provide="typeahead" data-items="4">
</body></html>`;

const dom = new JSDOM(PAGE, { runScripts: 'outside-only', pretendToBeVisual: true });
const w = dom.window;
w.eval(fs.readFileSync(path.join(JS, 'jquery.min.js'), 'utf8'));
w.eval(fs.readFileSync(path.join(JS, 'bootstrap.min.js'), 'utf8'));
const $ = w.jQuery;

const results = [];
function check(name, fn) {
  try {
    const v = fn();
    results.push([name, true, v === undefined ? '' : String(v)]);
  } catch (e) {
    results.push([name, false, e.message]);
  }
}

function click(id) {
  w.document.getElementById(id).dispatchEvent(
    new w.MouseEvent('click', { bubbles: true, cancelable: true }));
}

// --- jQuery -------------------------------------------------------------
check('jquery.min.js is stock jQuery 3.7.1', () => {
  const buf = fs.readFileSync(path.join(JS, 'jquery.min.js'));
  const sum = crypto.createHash('sha256').update(buf).digest('hex');
  if (sum !== JQUERY_371_SHA256) {
    throw new Error('sha256 ' + sum + ' does not match upstream 3.7.1');
  }
  if ($.fn.jquery !== '3.7.1') throw new Error('runtime reports ' + $.fn.jquery);
  return '3.7.1, digest verified';
});

// --- dropdown -----------------------------------------------------------
check('dropdown opens on click with href="#"', () => {
  $('#grp').removeClass('open');
  click('toggle');
  if (!$('#grp').hasClass('open')) throw new Error('no .open class applied');
  return 'ok';
});

check('dropdown closes on second click', () => {
  $('#grp').removeClass('open');
  click('toggle');
  click('toggle');
  if ($('#grp').hasClass('open')) throw new Error('stayed open');
  return 'ok';
});

check('markup in data-target builds no nodes and does not break the dropdown', () => {
  $('#grp2').removeClass('open');
  delete w.__XSS;
  click('toggle2');
  if (w.__XSS) throw new Error('payload executed');
  if (!$('#grp2').hasClass('open')) throw new Error('dropdown did not open');
  return 'safe and functional';
});

// --- typeahead ----------------------------------------------------------
check('typeahead auto-initialises from data-provide and reads data-items', () => {
  if (typeof $.fn.typeahead !== 'function') throw new Error('plugin missing');
  w.document.getElementById('searchinput')
    .dispatchEvent(new w.FocusEvent('focus', { bubbles: true }));
  const inst = $('#searchinput').data('typeahead');
  if (!inst) throw new Error('not initialised on focus');
  if (inst.options.items !== 4) throw new Error('data-items read as ' + inst.options.items);
  return 'items=4';
});

check('typeahead highlighter escapes source markup', () => {
  w.document.getElementById('searchinput')
    .dispatchEvent(new w.FocusEvent('focus', { bubbles: true }));
  const inst = $('#searchinput').data('typeahead');
  inst.query = 'foo';
  const out = inst.highlighter('<img src=x onerror=alert(1)>foo');
  if (out.includes('<img')) throw new Error('raw markup survived: ' + out);
  if (!out.includes('&lt;img')) throw new Error('not escaped: ' + out);
  if (!out.includes('<strong>foo</strong>')) throw new Error('highlight lost: ' + out);
  return 'escaped, highlight intact';
});

// --- removed plugins ----------------------------------------------------
check('CVE-carrying plugins are absent from the bundle', () => {
  const present = REMOVED.filter(p => typeof $.fn[p] === 'function');
  if (present.length) throw new Error('still present: ' + present.join(', '));
  return REMOVED.length + ' removed';
});

check('bootstrap.min.js keeps its licence header and patch markers', () => {
  const src = fs.readFileSync(path.join(JS, 'bootstrap.min.js'), 'utf8');
  if (!src.includes('LICENSE-2.0')) throw new Error('Apache licence header lost');
  for (const m of ['OCM-PATCH:selector-only', 'OCM-PATCH:escape-source']) {
    if (!src.includes(m)) throw new Error('missing marker ' + m);
  }
  return 'ok';
});

// jQuery 3 always fires ready asynchronously; the transition shim runs there.
setTimeout(() => {
  check('$.support.transition is set (transition shim kept)', () => {
    if (typeof $.support.transition === 'undefined') throw new Error('not set');
    return 'ok';
  });

  let failed = 0;
  for (const [name, ok, detail] of results) {
    if (!ok) failed++;
    console.log(`${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? '  -- ' + detail : ''}`);
  }
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
}, 100);
