#!/usr/bin/env python3
"""pattern-generator.py — Generate common regex patterns for specified languages.

Generates validated regex patterns for common use cases (email, URL, phone, date,
IP address, etc.) formatted for the target programming language.

Usage:
    ./pattern-generator.py <pattern-type> [--lang <language>] [--all-langs]
    ./pattern-generator.py --list                    # list available patterns
    ./pattern-generator.py email --lang python
    ./pattern-generator.py url --lang javascript
    ./pattern-generator.py --all --lang go           # all patterns for Go
    ./pattern-generator.py email --all-langs         # email for all languages
    ./pattern-generator.py date --lang java --test   # include test strings

Supported languages: javascript, python, go, rust, java
Supported patterns:  email, url, ipv4, ipv6, date-iso, date-us, phone-us,
                     phone-intl, uuid, hex-color, semver, credit-card, ssn,
                     zip-us, domain, slug, username, password-strong, mac-address,
                     time-24h, html-tag
"""

import sys
import json
import argparse
from textwrap import dedent

PATTERNS = {
    'email': {
        'regex': r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
        'description': 'Email address (practical, covers 99%+ real addresses)',
        'test_match': ['user@example.com', 'first.last+tag@domain.co.uk'],
        'test_no_match': ['user@', '@domain.com', 'user@.com', 'no-at-sign'],
    },
    'url': {
        'regex': r'^https?://[^\s/$.?#][^\s]*$',
        'description': 'HTTP/HTTPS URL',
        'test_match': ['https://example.com', 'http://example.com/path?q=1'],
        'test_no_match': ['ftp://x', 'not-a-url', '://missing-scheme'],
    },
    'ipv4': {
        'regex': r'^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$',
        'description': 'IPv4 address with octet validation (0-255)',
        'test_match': ['192.168.1.1', '10.0.0.0', '255.255.255.255'],
        'test_no_match': ['256.1.1.1', '192.168.1', '1.2.3.4.5'],
    },
    'ipv6': {
        'regex': r'^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$',
        'description': 'IPv6 address (full form, no :: abbreviation)',
        'test_match': ['2001:0db8:85a3:0000:0000:8a2e:0370:7334'],
        'test_no_match': ['2001:db8::1', '192.168.1.1', 'not-ipv6'],
    },
    'date-iso': {
        'regex': r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$',
        'description': 'ISO 8601 date (YYYY-MM-DD)',
        'test_match': ['2024-01-15', '1999-12-31'],
        'test_no_match': ['2024-13-01', '2024-00-15', '24-1-15'],
    },
    'date-us': {
        'regex': r'^(0[1-9]|1[0-2])/(0[1-9]|[12]\d|3[01])/\d{4}$',
        'description': 'US date format (MM/DD/YYYY)',
        'test_match': ['01/15/2024', '12/31/1999'],
        'test_no_match': ['13/01/2024', '1/5/24', '2024-01-15'],
    },
    'phone-us': {
        'regex': r'^(?:\+1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]?\d{3}[-.\s]?\d{4}$',
        'description': 'US phone number (flexible format)',
        'test_match': ['(555) 123-4567', '+1-555-123-4567', '5551234567'],
        'test_no_match': ['123-456', '+44 20 7946 0958', '555-123-456789'],
    },
    'phone-intl': {
        'regex': r'^\+?[1-9]\d{1,14}$',
        'description': 'International phone number (E.164 format)',
        'test_match': ['+14155552671', '+442071234567', '14155552671'],
        'test_no_match': ['+0123456789', '+', '0123456789012345678'],
    },
    'uuid': {
        'regex': r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        'description': 'UUID (any version, case-insensitive with i flag)',
        'test_match': ['550e8400-e29b-41d4-a716-446655440000'],
        'test_no_match': ['550e8400-e29b-41d4-a716', 'not-a-uuid'],
    },
    'hex-color': {
        'regex': r'^#(?:[0-9a-fA-F]{3}){1,2}$',
        'description': 'Hex color code (#RGB or #RRGGBB)',
        'test_match': ['#fff', '#1a2b3c', '#FFF', '#ABC123'],
        'test_no_match': ['#12345', '#gggggg', 'fff', '#1234567'],
    },
    'semver': {
        'regex': r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*))?(?:\+([\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*))?$',
        'description': 'Semantic version (semver 2.0)',
        'test_match': ['1.0.0', '1.2.3-beta.1', '0.1.0+build.123'],
        'test_no_match': ['1.0', 'v1.0.0', '01.0.0'],
    },
    'credit-card': {
        'regex': r'^(?:4\d{12}(?:\d{3})?|5[1-5]\d{14}|3[47]\d{13}|6(?:011|5\d{2})\d{12})$',
        'description': 'Credit card number (Visa, MC, Amex, Discover)',
        'test_match': ['4111111111111111', '5500000000000004', '378282246310005'],
        'test_no_match': ['1234567890', '411111111111111', 'not-a-card'],
    },
    'ssn': {
        'regex': r'^\d{3}-\d{2}-\d{4}$',
        'description': 'US Social Security Number (XXX-XX-XXXX)',
        'test_match': ['123-45-6789'],
        'test_no_match': ['123456789', '123-4-56789', '12-345-6789'],
    },
    'zip-us': {
        'regex': r'^\d{5}(?:-\d{4})?$',
        'description': 'US ZIP code (5-digit or ZIP+4)',
        'test_match': ['12345', '12345-6789'],
        'test_no_match': ['1234', '123456', '12345-67'],
    },
    'domain': {
        'regex': r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$',
        'description': 'Domain name',
        'test_match': ['example.com', 'sub.domain.co.uk', 'a.io'],
        'test_no_match': ['-example.com', '.com', 'example', 'a.b'],
    },
    'slug': {
        'regex': r'^[a-z0-9]+(?:-[a-z0-9]+)*$',
        'description': 'URL slug (lowercase alphanumeric with hyphens)',
        'test_match': ['hello-world', 'my-post-123', 'single'],
        'test_no_match': ['-leading', 'trailing-', 'UPPER', 'has space'],
    },
    'username': {
        'regex': r'^[a-zA-Z][a-zA-Z0-9._-]{2,29}$',
        'description': 'Username (3-30 chars, starts with letter)',
        'test_match': ['john_doe', 'user123', 'Alice.Bob'],
        'test_no_match': ['1user', 'ab', 'a' * 31, '_user'],
    },
    'password-strong': {
        'regex': r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{8,}$',
        'description': 'Strong password (8+ chars, upper+lower+digit+special)',
        'test_match': ['MyP@ss1!', 'Str0ng!Pass'],
        'test_no_match': ['weak', 'nouppercase1!', 'NOLOWER1!', 'NoDigit!!'],
    },
    'mac-address': {
        'regex': r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$',
        'description': 'MAC address (colon or hyphen separated)',
        'test_match': ['00:1A:2B:3C:4D:5E', 'AA-BB-CC-DD-EE-FF'],
        'test_no_match': ['00:1A:2B:3C:4D', 'GG:HH:II:JJ:KK:LL'],
    },
    'time-24h': {
        'regex': r'^([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$',
        'description': '24-hour time (HH:MM or HH:MM:SS)',
        'test_match': ['23:59', '00:00', '14:30:59'],
        'test_no_match': ['24:00', '12:60', '1:30'],
    },
    'html-tag': {
        'regex': r'<([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>(.*?)</\1>',
        'description': 'HTML tag with content (simple, not for parsing HTML)',
        'test_match': ['<div>content</div>', '<p>text</p>'],
        'test_no_match': ['<div>unclosed', 'not html'],
    },
}

LANG_TEMPLATES = {
    'javascript': {
        'ext': 'js',
        'format': lambda name, regex, desc: dedent(f"""\
            // {desc}
            const {_to_camel(name)}Re = /{regex}/;

            // Usage:
            // {_to_camel(name)}Re.test(input);
            // input.match({_to_camel(name)}Re);
        """),
    },
    'python': {
        'ext': 'py',
        'format': lambda name, regex, desc: dedent(f"""\
            # {desc}
            {_to_snake(name)}_re = re.compile(r'{regex}')

            # Usage:
            # {_to_snake(name)}_re.search(input)
            # {_to_snake(name)}_re.fullmatch(input)
        """),
    },
    'go': {
        'ext': 'go',
        'format': lambda name, regex, desc: dedent(f"""\
            // {desc}
            var {_to_camel(name)}Re = regexp.MustCompile(`{regex}`)

            // Usage:
            // {_to_camel(name)}Re.MatchString(input)
            // {_to_camel(name)}Re.FindString(input)
        """),
    },
    'rust': {
        'ext': 'rs',
        'format': lambda name, regex, desc: dedent(f"""\
            // {desc}
            static {_to_screaming(name)}_RE: Lazy<Regex> = Lazy::new(|| {{
                Regex::new(r"{regex}").unwrap()
            }});

            // Usage:
            // {_to_screaming(name)}_RE.is_match(input)
            // {_to_screaming(name)}_RE.find(input)
        """),
    },
    'java': {
        'ext': 'java',
        'format': lambda name, regex, desc: dedent(f"""\
            // {desc}
            private static final Pattern {_to_screaming(name)}_PATTERN =
                Pattern.compile("{_java_escape(regex)}");

            // Usage:
            // {_to_screaming(name)}_PATTERN.matcher(input).matches()
            // {_to_screaming(name)}_PATTERN.matcher(input).find()
        """),
    },
}


def _to_camel(s: str) -> str:
    parts = s.replace('-', '_').split('_')
    return parts[0] + ''.join(p.capitalize() for p in parts[1:])


def _to_snake(s: str) -> str:
    return s.replace('-', '_').upper().lower()


def _to_screaming(s: str) -> str:
    return s.replace('-', '_').upper()


def _java_escape(s: str) -> str:
    return s.replace('\\', '\\\\')


def generate_pattern(name: str, lang: str, show_tests: bool = False) -> str:
    info = PATTERNS[name]
    tmpl = LANG_TEMPLATES[lang]
    output = tmpl['format'](name, info['regex'], info['description'])

    if show_tests:
        output += f"\n// Test matches: {info['test_match']}\n"
        output += f"// Test non-matches: {info['test_no_match']}\n"

    return output


def list_patterns():
    print("\nAvailable pattern types:\n")
    for name, info in sorted(PATTERNS.items()):
        print(f"  {name:20s} {info['description']}")
    print(f"\n  Total: {len(PATTERNS)} patterns")
    print(f"\nSupported languages: {', '.join(sorted(LANG_TEMPLATES.keys()))}")


def main():
    parser = argparse.ArgumentParser(
        description='Generate common regex patterns for specified languages.'
    )
    parser.add_argument('pattern', nargs='?',
                        help='Pattern type (e.g., email, url, ipv4)')
    parser.add_argument('--lang', '-l', default='python',
                        choices=list(LANG_TEMPLATES.keys()),
                        help='Target language (default: python)')
    parser.add_argument('--all', action='store_true',
                        help='Generate all patterns')
    parser.add_argument('--all-langs', action='store_true',
                        help='Generate pattern for all languages')
    parser.add_argument('--list', action='store_true',
                        help='List available patterns')
    parser.add_argument('--test', action='store_true',
                        help='Include test strings')
    parser.add_argument('--json', action='store_true',
                        help='Output as JSON')

    args = parser.parse_args()

    if args.list:
        list_patterns()
        return

    if args.json:
        if args.all:
            print(json.dumps(PATTERNS, indent=2))
        elif args.pattern and args.pattern in PATTERNS:
            print(json.dumps({args.pattern: PATTERNS[args.pattern]}, indent=2))
        else:
            print(json.dumps(PATTERNS, indent=2))
        return

    if args.all:
        names = sorted(PATTERNS.keys())
    elif args.pattern:
        if args.pattern not in PATTERNS:
            print(f"Unknown pattern: {args.pattern}")
            print(f"Available: {', '.join(sorted(PATTERNS.keys()))}")
            sys.exit(1)
        names = [args.pattern]
    else:
        parser.print_help()
        sys.exit(1)

    if args.all_langs:
        langs = sorted(LANG_TEMPLATES.keys())
    else:
        langs = [args.lang]

    for lang in langs:
        if len(langs) > 1:
            print(f"\n{'='*60}")
            print(f"  Language: {lang}")
            print(f"{'='*60}\n")

        for name in names:
            print(generate_pattern(name, lang, args.test))


if __name__ == '__main__':
    main()
