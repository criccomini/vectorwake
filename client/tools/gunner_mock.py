#!/usr/bin/env python3
"""Draw a carrier and its gunners, for looking at rather than for playing.

    client/tools/gunner_mock.py out/            # all seven hulls
    client/tools/gunner_mock.py out/ anvil apex
    client/tools/gunner_mock.py out/ --drone    # the other candidate

Gunners are not built. Nothing in `client/` draws one, `sim/` has no notion of
a ship riding another, and the roster has no hull for it. This exists so the
drawing can be argued about before any of that is true, which is cheaper than
arguing about it afterwards.

What keeps it honest is that it draws nothing of its own. The hull outlines,
the plates, the panel lines, the canopies and the hardpoints are parsed out of
`client/arena/world.lua`, and the colours out of `client/arena/palette.lua`,
so a hull that changes there changes here. The one thing invented is the gun
glyph, which is the thing under discussion.

The page is `gunner_mock.html`, a canvas that reimplements `world.M.ship` in
JavaScript. That is a second copy of a drawing routine and it will drift; it
is a mock, and the moment gunners are real this should be deleted rather than
maintained. Screenshots come out of the Chromium that Playwright installs,
which is the only browser on the machines this runs on.
"""

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT = os.path.dirname(HERE)
NAMES = ['apex', 'wedge', 'chord', 'anvil', 'cipher', 'facet', 'lattice']

CHROME = [
    '/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell',
    os.path.expanduser('~/.cache/ms-playwright/chromium_headless_shell-1194/'
                       'chrome-linux/headless_shell'),
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
]


def hulls():
    """M.HULLS out of world.lua, which is a Lua table of numbers and nothing
    else, so it parses without a Lua interpreter."""
    src = open(os.path.join(CLIENT, 'arena', 'world.lua'), encoding='utf-8').read()
    i = src.index('{', src.index('M.HULLS = {'))
    depth, j = 0, i
    while True:
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
            if depth == 0:
                break
        j += 1
    block = re.sub(r'--[^\n]*', '', src[i:j + 1])

    pos = 0

    def skip():
        nonlocal pos
        while pos < len(block) and block[pos] in ' \t\r\n,':
            pos += 1

    def value():
        nonlocal pos
        skip()
        if block[pos] == '{':
            pos += 1
            out, keyed = [], {}
            while True:
                skip()
                if block[pos] == '}':
                    pos += 1
                    break
                m = re.match(r'([A-Za-z_]\w*)\s*=', block[pos:])
                if m:
                    pos += m.end()
                    keyed[m.group(1)] = value()
                else:
                    out.append(value())
            return keyed if keyed else out
        m = re.match(r'-?\d+(\.\d+)?', block[pos:])
        if not m:
            raise SystemExit('world.lua: cannot parse %r' % block[pos:pos + 40])
        pos += m.end()
        return float(m.group(0))

    parsed = value()
    for name, h in zip(NAMES, parsed):
        h['name'] = name.capitalize()
    return parsed


def browser():
    for path in CHROME:
        if os.path.exists(path):
            return path
    raise SystemExit('no chromium found; looked in:\n  ' + '\n  '.join(CHROME))


def main(argv):
    if not argv:
        raise SystemExit(__doc__.strip().splitlines()[2].strip())
    out = argv[0]
    rest = [a.lower() for a in argv[1:]]
    variant = 'drone' if '--drone' in rest else 'gun'
    want = [a for a in rest if not a.startswith('--')] or NAMES
    os.makedirs(out, exist_ok=True)

    page = open(os.path.join(HERE, 'gunner_mock.html'), encoding='utf-8').read()
    page = page.replace('HULLS_JSON', json.dumps(hulls()))
    built = os.path.join(out, '.gunner_mock.built.html')
    open(built, 'w', encoding='utf-8').write(page)

    chrome = browser()
    for name in want:
        if name not in NAMES:
            raise SystemExit('unknown hull %r, expected one of %s'
                             % (name, ', '.join(NAMES)))
        shot = os.path.join(out, 'carrier-%s-%s.png' % (name, variant))
        subprocess.run([
            chrome, '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
            '--screenshot=' + shot, '--window-size=1360,660',
            '--virtual-time-budget=2000',
            'file://%s?i=%d&v=%s' % (os.path.abspath(built),
                                     NAMES.index(name), variant),
        ], check=True, capture_output=True)
        print(shot)
    os.remove(built)


if __name__ == '__main__':
    main(sys.argv[1:])
