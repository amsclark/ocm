#!/usr/bin/env python3
"""Fail the build on any Snyk Code finding that is not in .snyk-code-accepted.

`snyk code test` exits 1 on any finding at or above the threshold, and it has
no working way to say "this one has been read and is not a vulnerability":
.snyk ignore entries are not applied to Snyk Code by the CLI, and dismissing an
alert in the GitHub Security tab changes only what GitHub displays. So the scan
itself cannot be the gate without being permanently red.

This is the gate instead. The scan still runs at the same threshold and still
reports everything; its SARIF is compared against the accepted list, and
anything not on that list fails the build.

Usage:
    snyk_code_gate.py <sarif file> [accepted file]

Exit codes:
    0  every finding is accounted for
    1  a finding is not accepted, or the accepted list is malformed
    2  the SARIF could not be read, which is not a pass
"""

import collections
import json
import os
import sys

# A reason shorter than this is not a reason. The point of the file is that
# somebody wrote down why, and "n/a" is how that stops being true.
MIN_REASON = 40


def load_accepted(path):
	"""Read the accepted list. Returns {(rule, path): [count, reason]}."""
	accepted = {}
	problems = []

	with open(path, encoding='utf-8') as handle:
		for lineno, raw in enumerate(handle, 1):
			line = raw.strip()

			if not line or line.startswith('#'):
				continue

			fields = [f.strip() for f in line.split('|', 3)]

			if len(fields) != 4:
				problems.append('%s:%d: expected "rule | path | count | reason"' % (path, lineno))
				continue

			rule, filepath, count, reason = fields

			if not count.isdigit() or int(count) < 1:
				problems.append('%s:%d: count must be a positive whole number, got %r' % (path, lineno, count))
				continue

			if len(reason) < MIN_REASON:
				problems.append('%s:%d: reason is %d characters; write down why (at least %d)'
					% (path, lineno, len(reason), MIN_REASON))
				continue

			key = (rule, filepath)

			if key in accepted:
				problems.append('%s:%d: %s in %s is listed twice; raise the count instead'
					% (path, lineno, rule, filepath))
				continue

			accepted[key] = [int(count), reason]

	return accepted, problems


def load_findings(path):
	"""Read the SARIF. Returns {(rule, path): count} and the total."""
	with open(path, encoding='utf-8') as handle:
		report = json.load(handle)

	found = collections.Counter()
	total = 0

	for run in report.get('runs', []):
		for result in run.get('results', []):
			# A suppression the scanner itself applied is already handled.
			if result.get('suppressions'):
				continue

			locations = result.get('locations') or []

			if not locations:
				# Nowhere to attribute it, so it cannot be matched against the
				# list. Count it, and it will be reported as unaccepted.
				found[(result.get('ruleId', '?'), '<no location>')] += 1
				total += 1
				continue

			physical = locations[0].get('physicalLocation', {})
			uri = physical.get('artifactLocation', {}).get('uri', '<no location>')
			found[(result.get('ruleId', '?'), uri)] += 1
			total += 1

	return found, total


def main(argv):
	if len(argv) < 2:
		sys.stderr.write(__doc__)
		return 2

	sarif_path = argv[1]
	accepted_path = argv[2] if len(argv) > 2 else '.snyk-code-accepted'

	if not os.path.exists(sarif_path):
		print('snyk-code gate: no SARIF at %s -- the scan did not produce a report' % sarif_path)
		return 2

	try:
		found, total = load_findings(sarif_path)
	except (ValueError, KeyError, TypeError) as err:
		print('snyk-code gate: %s is not a SARIF report this can read: %s' % (sarif_path, err))
		return 2

	if not os.path.exists(accepted_path):
		print('snyk-code gate: no accepted list at %s' % accepted_path)
		return 1

	accepted, problems = load_accepted(accepted_path)

	if problems:
		print('snyk-code gate: the accepted list has %d problem(s):' % len(problems))
		for problem in problems:
			print('  %s' % problem)
		return 1

	unaccepted = []
	over = []

	for key in sorted(found):
		rule, filepath = key
		count = found[key]

		if key not in accepted:
			unaccepted.append((rule, filepath, count))
			continue

		allowed = accepted[key][0]

		if count > allowed:
			over.append((rule, filepath, count, allowed))

	stale = []

	for key in sorted(accepted):
		allowed = accepted[key][0]
		count = found.get(key, 0)

		if count < allowed:
			stale.append((key[0], key[1], count, allowed))

	print('snyk-code gate: %d finding(s) in the report, %d group(s) accepted'
		% (total, len(accepted)))

	if stale:
		# Not a failure. A finding that went away is the outcome this file is
		# meant to make possible, and failing the build for it would mean a
		# fix cannot land without editing the list in the same commit.
		print()
		print('These accepted entries matched fewer findings than they allow.')
		print('Either the code was fixed or the rule changed; trim the list.')
		for rule, filepath, count, allowed in stale:
			print('  %s in %s: %d found, %d accepted' % (rule, filepath, count, allowed))

	if not unaccepted and not over:
		print()
		print('PASS: every finding is on the accepted list.')
		return 0

	print()
	print('FAIL: the report has findings that are not accepted.')

	if unaccepted:
		print()
		print('Not on the list at all:')
		for rule, filepath, count in unaccepted:
			print('  %s in %s (%d)' % (rule, filepath, count))

	if over:
		print()
		print('More findings than the list accepts:')
		for rule, filepath, count, allowed in over:
			print('  %s in %s: %d found, %d accepted' % (rule, filepath, count, allowed))

	print()
	print('Fix the finding, or -- if it is not a vulnerability, or cannot be')
	print('fixed here -- add a line to %s saying why. A line without a' % accepted_path)
	print('reason that somebody can check is not accepted.')

	return 1


if __name__ == '__main__':
	sys.exit(main(sys.argv))
