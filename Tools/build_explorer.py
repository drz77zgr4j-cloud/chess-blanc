#!/usr/bin/env python3
"""Count what club players actually play, from the free Lichess game database.

Streams monthly PGN dumps (zstd) from database.lichess.org without saving them, keeps rated games
between 1000 and 1900 average rating at blitz speed or slower, and counts every move in the first
MAX_PLY plies with its results. Output: Tools/data/explorer-table.json
    {"<san prefix>": {"<next san>": [white_wins, draws, black_wins], ...}, ...}

    Tools/.venv/bin/python Tools/build_explorer.py 2014-06 2015-01
"""
import collections
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, 'data', 'explorer-table.json')
MAX_PLY = 22
MIN_RATING, MAX_RATING = 1000, 1900
MIN_BASE_SECONDS = 180
PRUNE_EVERY = 250_000

table = collections.defaultdict(dict)   # prefix -> {san: [w, d, b]}
TOKEN = re.compile(r'\{[^}]*\}|\d+\.(?:\.\.)?|[^\s]+')


def add_game(sans, result):
    idx = 0 if result == '1-0' else 2 if result == '0-1' else 1
    prefix = ''
    for i, san in enumerate(sans[:MAX_PLY]):
        bucket = table[prefix]
        c = bucket.get(san)
        if c is None:
            c = bucket[san] = [0, 0, 0]
        c[idx] += 1
        prefix = san if not prefix else prefix + ' ' + san


def prune(min_count):
    """Drop rare tails so memory stays bounded. The first few plies are always kept."""
    dead = []
    for prefix, moves in table.items():
        if prefix.count(' ') < 5:
            continue
        for san in [s for s, c in moves.items() if sum(c) < min_count]:
            del moves[san]
        if not moves:
            dead.append(prefix)
    for p in dead:
        del table[p]


def stream(month):
    url = f'https://database.lichess.org/standard/lichess_db_standard_rated_{month}.pgn.zst'
    curl = subprocess.Popen(['curl', '-sfL', url], stdout=subprocess.PIPE)
    zstd = subprocess.Popen(['zstd', '-dc'], stdin=curl.stdout, stdout=subprocess.PIPE, text=True, bufsize=1 << 20)
    headers = {}
    for line in zstd.stdout:
        if line.startswith('['):
            k, _, v = line[1:].partition(' ')
            headers[k] = v.strip().rstrip(']').strip('"')
        elif line.strip() and not line.startswith('['):
            yield headers, line
            headers = {}
    zstd.wait()
    curl.wait()


def main():
    months = sys.argv[1:] or ['2014-06', '2015-01']
    kept = seen = 0
    started = time.time()
    for month in months:
        print(f'Streaming {month}…', flush=True)
        for h, movetext in stream(month):
            seen += 1
            try:
                wr, br = int(h.get('WhiteElo', 0)), int(h.get('BlackElo', 0))
                base = int(h.get('TimeControl', '0+0').split('+')[0])
            except ValueError:
                continue
            if not (MIN_RATING <= (wr + br) / 2 <= MAX_RATING) or base < MIN_BASE_SECONDS:
                continue
            sans = [t.rstrip('+#?!') for t in TOKEN.findall(movetext)
                    if not t.startswith('{') and not t[0].isdigit() and t not in ('*',)]
            sans = [s for s in sans if s and s not in ('1-0', '0-1', '1/2-1/2')]
            if len(sans) < 6:
                continue
            add_game(sans, h.get('Result', '*'))
            kept += 1
            if kept % PRUNE_EVERY == 0:
                prune(2)
                print(f'  {kept:,} games kept of {seen:,} · {len(table):,} positions · {time.time() - started:.0f}s', flush=True)
    prune(5)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w') as f:
        json.dump(table, f, separators=(',', ':'))
    print(f'Done: {kept:,} games, {len(table):,} positions, {os.path.getsize(OUT) // 1024 // 1024} MB', flush=True)


if __name__ == '__main__':
    main()
