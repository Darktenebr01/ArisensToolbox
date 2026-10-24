#!/usr/bin/env python3
"""deferredcheck.py — fail if an `except ... as <name>:` variable is referenced
inside a deferred `after(0, lambda...)` callback.

Python deletes the exception variable when the except block exits, so a
lambda that runs later raises:
  NameError: cannot access free variable 'e' ...
The fix is to capture the message in a plain local first:
    except ... as e:
        err = f"Error: {e}"
        self.after(0, lambda: ...set_status(err))
"""
import re, sys, glob

bad = 0
for f in sorted(glob.glob('ui/**/*.py', recursive=True)):
    lines = open(f, encoding='utf-8', errors='replace').read().split('\n')
    for i, ln in enumerate(lines):
        if 'after(0,' in ln and 'lambda' in ln:
            exc = None
            for j in range(max(0, i - 6), i):
                m = re.search(r'except\b.*\bas\s+(\w+)\s*:', lines[j])
                if m:
                    exc = (j + 1, m.group(1))
            if exc:
                _, name = exc
                # The lambda may span several lines (v0.96: a two-line
                # tuple lambda hid an except-var on its second line).
                # Accumulate until the after( call's parens balance.
                span = ln[ln.index('lambda'):]
                depth = ln.count('(') - ln.count(')')
                k = i
                while depth > 0 and k + 1 < len(lines):
                    k += 1
                    span += '\n' + lines[k]
                    depth += lines[k].count('(') - lines[k].count(')')
                if re.search(r'\{' + re.escape(name) + r'\}|\b' + re.escape(name) + r'\b', span):
                    print(f"{f}:{i+1}: deferred lambda uses except-var '{name}' (except at line {exc[0]})")
                    print(f"    {ln.strip()[:110]}")
                    bad += 1
if bad:
    print(f"\nFAILED: {bad} deferred except-var reference(s)")
    sys.exit(1)
print("deferredcheck: OK - no except-var captured by deferred lambdas")
