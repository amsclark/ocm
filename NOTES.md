# Required handoffs

- Add `<script src="%%[base_url]%%/js/case-lsc-compliance-inline.js"></script>` to `cms/subtemplates/case-lsc-compliance.html`.
- In `cms/js/activity-inline.js`, bind change on `.js-set-funding` to `setFunding(this.value)` and change on `.js-set-sms-visibility` to `setSmsVisibility()`. When both classes are present, call funding first, then SMS visibility. `cms/activity.php` preserves both conditions and the `plmenu` class.
- Add `<script src="%%[base_url]%%/js/field-list-inline.js"></script>` to `cms/reports/megareport/form.html` and `cms/reports/megapartyreport/form.html`. These are the two templates that render `field_list`; each renders cases, contacts, and activities. The delegated change listener calls `update(field_name, field_text)`, as defined in `cms/js/megareport.js`.

# Scope note

- The requested timer binding calls `setFunding` whenever `#case_id` changes. Previously its inline argument was conditional on `autofill_time_funding`. The requested empty argument array provides no setting marker to the browser, so the new binding follows the explicit ID-binding instruction.
