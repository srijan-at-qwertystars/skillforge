#!/usr/bin/env python3
"""redos-checker.py — Analyze regex patterns for ReDoS vulnerabilities.

Detects patterns susceptible to catastrophic backtracking (exponential time)
by identifying dangerous constructs and optionally timing test inputs.

Usage:
    ./redos-checker.py '<pattern>'
    ./redos-checker.py '<pattern>' --test          # run timing test
    ./redos-checker.py '<pattern>' --test --max-n 30
    ./redos-checker.py -f patterns.txt             # check file of patterns
    echo '(a+)+$' | ./redos-checker.py -

Examples:
    ./redos-checker.py '(a+)+b'
    ./redos-checker.py '([a-zA-Z]+)*$' --test
    ./redos-checker.py '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$'
"""

import re
import sys
import time
import argparse
from typing import NamedTuple


class Vulnerability(NamedTuple):
    severity: str  # HIGH, MEDIUM, LOW
    rule: str
    detail: str
    suggestion: str


def analyze_pattern(pattern: str) -> list[Vulnerability]:
    """Static analysis of a regex pattern for ReDoS vulnerabilities."""
    vulns = []

    # Rule 1: Nested quantifiers — (x+)+, (x*)+, (x+)*, (x*)*
    nested_quant = re.findall(
        r'\((?:[^()]*(?:\([^()]*\))*[^()]*)\)[*+]\??\)?[*+]', pattern
    )
    # Simpler check with known patterns
    if re.search(r'\([^()]*[+*]\)\s*[+*]', pattern):
        vulns.append(Vulnerability(
            severity='HIGH',
            rule='nested-quantifier',
            detail='Nested quantifiers detected (e.g., (x+)+ or (x*)*). '
                   'This creates exponential backtracking paths.',
            suggestion='Flatten nested quantifiers: (a+)+ → a+, or use atomic groups (?>a+).'
        ))

    # Rule 2: Quantified group with internal alternation that can overlap
    if re.search(r'\((?:[^()]*\|[^()]*)\)\s*[+*]', pattern):
        # Check if alternation branches overlap
        groups_with_alt = re.findall(r'\(([^()]*\|[^()]*)\)[+*]', pattern)
        for group in groups_with_alt:
            branches = group.split('|')
            if len(branches) >= 2:
                # Simple overlap check: if branches share leading characters
                for i, b1 in enumerate(branches):
                    for b2 in branches[i + 1:]:
                        b1_clean = re.sub(r'[\\()\[\]{}+*?.|^$]', '', b1)
                        b2_clean = re.sub(r'[\\()\[\]{}+*?.|^$]', '', b2)
                        if b1_clean and b2_clean and (
                            b1_clean[0] == b2_clean[0] or
                            set(b1_clean) & set(b2_clean)
                        ):
                            vulns.append(Vulnerability(
                                severity='HIGH',
                                rule='overlapping-alternation',
                                detail=f'Alternation branches may overlap: '
                                       f'"{b1}" and "{b2}" in quantified group.',
                                suggestion='Make alternation branches mutually exclusive, '
                                           'or combine into a single branch.'
                            ))
                            break

    # Rule 3: Adjacent quantifiers on potentially overlapping patterns
    if re.search(r'(?:\\[wdWDS]|\.\*?|\[[^\]]+\])[+*].*(?:\\[wdWDS]|\.\*?|\[[^\]]+\])[+*]', pattern):
        # Check for patterns like \d+\d+ or .*.*
        adj_quants = re.findall(
            r'((?:\\[wdWDS]|\.\*?|\[[^\]]+\])[+*]\??)', pattern
        )
        if len(adj_quants) >= 2:
            vulns.append(Vulnerability(
                severity='MEDIUM',
                rule='adjacent-quantifiers',
                detail='Adjacent quantifiers found that may match overlapping characters. '
                       'This can cause quadratic or exponential backtracking.',
                suggestion='Combine adjacent quantifiers into one, '
                           'or add unambiguous separators between them.'
            ))

    # Rule 4: Star or plus on group containing star or plus
    if re.search(r'\([^()]*(?:[+*])[^()]*\)\s*(?:[+*])', pattern):
        if 'nested-quantifier' not in [v.rule for v in vulns]:
            vulns.append(Vulnerability(
                severity='HIGH',
                rule='nested-quantifier-variant',
                detail='Quantifier applied to group that contains a quantifier.',
                suggestion='Restructure to avoid nesting: '
                           '(a+)+ → a+, ([a-z]+)* → [a-z]*'
            ))

    # Rule 5: .* at start without anchor (can cause excessive scanning)
    if re.search(r'^\.\*[^?+]', pattern) or re.search(r'(?<!\^)\.\*', pattern):
        if not pattern.startswith('^'):
            vulns.append(Vulnerability(
                severity='LOW',
                rule='unanchored-wildcard',
                detail='.* without start anchor causes the engine to retry '
                       'the pattern at every position in the input.',
                suggestion='Add ^ anchor at start, or use a more specific '
                           'leading pattern instead of .*'
            ))

    # Rule 6: Backreference inside quantified group
    if re.search(r'\([^()]*\\[1-9][^()]*\)\s*[+*]', pattern):
        vulns.append(Vulnerability(
            severity='MEDIUM',
            rule='quantified-backreference',
            detail='Backreference inside a quantified group can cause '
                   'complex backtracking behavior.',
            suggestion='Move backreference outside the quantified group, '
                       'or verify the pattern manually with worst-case input.'
        ))

    # Rule 7: Repetition of optional patterns (a?)+
    if re.search(r'\([^()]*\?\s*\)\s*[+*]', pattern):
        vulns.append(Vulnerability(
            severity='HIGH',
            rule='quantified-optional',
            detail='Quantified group containing only optional elements '
                   '(e.g., (a?)+ or (a?b?)*) creates exponential paths.',
            suggestion='Rewrite to make the group non-optional: '
                       '(a?)+ → a* or [ab]*'
        ))

    # Rule 8: End anchor after quantified group (common attack vector)
    if re.search(r'[+*]\)\s*[+*].*\$', pattern):
        vulns.append(Vulnerability(
            severity='HIGH',
            rule='quantified-before-anchor',
            detail='Nested quantifier followed by end anchor ($) is a '
                   'classic ReDoS pattern — forces full backtracking on non-match.',
            suggestion='Flatten the quantifier structure or validate '
                       'input length before applying this pattern.'
        ))

    return vulns


def timing_test(pattern: str, max_n: int = 25, timeout: float = 5.0) -> dict:
    """Run exponential backtracking timing test."""
    results = {
        'exponential_detected': False,
        'timings': [],
        'aborted_at': None,
    }

    compiled = re.compile(pattern)

    # Determine a test character that matches the inner part of the pattern
    # Common: 'a' for (a+)+, digit for (\d+)+, etc.
    test_chars = ['a', '0', 'x', ' ', 'A']
    fail_char = '!'

    best_char = 'a'
    for ch in test_chars:
        try:
            if compiled.search(ch * 5):
                best_char = ch
                break
        except Exception:
            continue

    prev_time = 0
    for n in range(1, max_n + 1):
        test_input = best_char * n + fail_char
        start = time.perf_counter()
        try:
            compiled.search(test_input)
        except Exception:
            pass
        elapsed = time.perf_counter() - start

        results['timings'].append({'n': n, 'time_ms': elapsed * 1000})

        # Check for exponential growth
        if elapsed > 0.01 and prev_time > 0.001:
            ratio = elapsed / prev_time
            if ratio > 1.8:  # Exponential if each step roughly doubles
                results['exponential_detected'] = True

        if elapsed > timeout:
            results['aborted_at'] = n
            break

        prev_time = elapsed

    return results


def format_severity(severity: str) -> str:
    colors = {
        'HIGH': '\033[1;31m',    # Bold red
        'MEDIUM': '\033[1;33m',  # Bold yellow
        'LOW': '\033[0;33m',     # Yellow
    }
    reset = '\033[0m'
    return f"{colors.get(severity, '')}{severity}{reset}"


def print_report(pattern: str, vulns: list[Vulnerability],
                 timing_results: dict | None = None):
    """Print formatted analysis report."""
    print(f"\n{'='*60}")
    print(f"  ReDoS Analysis Report")
    print(f"{'='*60}")
    print(f"  Pattern: {pattern}")
    print(f"{'='*60}\n")

    if not vulns:
        print("  \033[0;32m✅ No obvious ReDoS vulnerabilities detected.\033[0m")
        print("  Note: Static analysis cannot catch all cases.")
        print("  Consider running with --test for dynamic analysis.\n")
    else:
        print(f"  Found {len(vulns)} potential issue(s):\n")
        for i, v in enumerate(vulns, 1):
            print(f"  {i}. [{format_severity(v.severity)}] {v.rule}")
            print(f"     {v.detail}")
            print(f"     💡 {v.suggestion}")
            print()

    if timing_results:
        print(f"{'─'*60}")
        print("  Dynamic Timing Analysis")
        print(f"{'─'*60}\n")

        # Show select timing entries
        for entry in timing_results['timings']:
            n = entry['n']
            t = entry['time_ms']
            bar_len = min(int(t * 10), 50)
            bar = '█' * bar_len
            if t > 1000:
                print(f"  n={n:3d}  {t:10.1f} ms  {bar} ⚠️")
            elif t > 100:
                print(f"  n={n:3d}  {t:10.1f} ms  {bar}")
            elif t > 1:
                print(f"  n={n:3d}  {t:10.3f} ms  {bar}")
            else:
                print(f"  n={n:3d}  {t:10.3f} ms")

        print()
        if timing_results['exponential_detected']:
            print("  \033[1;31m🚨 EXPONENTIAL GROWTH DETECTED — pattern is vulnerable to ReDoS!\033[0m")
        else:
            print("  \033[0;32m✅ No exponential growth detected in timing test.\033[0m")

        if timing_results['aborted_at']:
            print(f"  ⏱️  Test aborted at n={timing_results['aborted_at']} (timeout)")
        print()

    # Overall verdict
    has_high = any(v.severity == 'HIGH' for v in vulns)
    exp_detected = timing_results and timing_results['exponential_detected']

    print(f"{'='*60}")
    if has_high or exp_detected:
        print("  \033[1;31mVERDICT: VULNERABLE — do NOT use on untrusted input\033[0m")
    elif vulns:
        print("  \033[1;33mVERDICT: SUSPICIOUS — review carefully before use\033[0m")
    else:
        print("  \033[0;32mVERDICT: LIKELY SAFE — no issues found\033[0m")
    print(f"{'='*60}\n")


def main():
    parser = argparse.ArgumentParser(
        description='Analyze regex patterns for ReDoS vulnerabilities.'
    )
    parser.add_argument('pattern', nargs='?', help='Regex pattern to analyze')
    parser.add_argument('-f', '--file', help='File with patterns (one per line)')
    parser.add_argument('--test', action='store_true',
                        help='Run dynamic timing test')
    parser.add_argument('--max-n', type=int, default=25,
                        help='Max input length for timing test (default: 25)')
    parser.add_argument('--timeout', type=float, default=5.0,
                        help='Timeout in seconds for timing test (default: 5.0)')

    args = parser.parse_args()

    patterns = []

    if args.file:
        with open(args.file) as f:
            patterns = [line.strip() for line in f if line.strip() and not line.startswith('#')]
    elif args.pattern == '-':
        patterns = [line.strip() for line in sys.stdin if line.strip()]
    elif args.pattern:
        patterns = [args.pattern]
    else:
        parser.print_help()
        sys.exit(1)

    # Validate that patterns compile
    for pattern in patterns:
        try:
            re.compile(pattern)
        except re.error as e:
            print(f"\033[1;31mError: Invalid regex pattern: {e}\033[0m")
            print(f"  Pattern: {pattern}")
            continue

        vulns = analyze_pattern(pattern)
        timing_results = None
        if args.test:
            timing_results = timing_test(pattern, args.max_n, args.timeout)
        print_report(pattern, vulns, timing_results)


if __name__ == '__main__':
    main()
