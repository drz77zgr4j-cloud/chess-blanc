#!/usr/bin/env python3
"""Export the app's offline opening book from Tools/data/explorer-table.json.

Output: BlancChess/Repertoires/book.json
    {"positions": {"<placement side castling>": [[uci, san, white, draws, black], ...]},
     "names": {"<placement side castling>": "Opening name"}}
Positions need MIN_GAMES club games; each keeps its MAX_MOVES most played moves.
"""
import json
import os

import chess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(ROOT, 'Tools', 'data', 'explorer-table.json')
OUT = os.path.join(ROOT, 'BlancChess', 'Repertoires', 'book.json')
MIN_GAMES = 30
MAX_MOVES = 10
MAX_PLY = 18


def key(board):
    return ' '.join(board.fen().split()[:3])


def main():
    table = json.load(open(TABLE))
    positions = {}
    for prefix, moves in table.items():
        sans = prefix.split() if prefix else []
        if len(sans) > MAX_PLY:
            continue
        total = sum(sum(v) for v in moves.values())
        if total < MIN_GAMES:
            continue
        board = chess.Board()
        try:
            for s in sans:
                board.push_san(s)
        except ValueError:
            continue
        k = key(board)
        rows = []
        for san, (w, d, b) in sorted(moves.items(), key=lambda kv: -sum(kv[1]))[:MAX_MOVES]:
            try:
                mv = board.parse_san(san)
            except ValueError:
                continue
            full = board.san(mv)
            uci = mv.uci()
            rows.append([uci, full, w, d, b])
        if not rows:
            continue
        # Transpositions: merge counts if the same position arrives by another order.
        if k in positions:
            merged = {r[0]: r for r in positions[k]}
            for r in rows:
                if r[0] in merged:
                    m = merged[r[0]]
                    merged[r[0]] = [m[0], m[1], m[2] + r[2], m[3] + r[3], m[4] + r[4]]
                else:
                    merged[r[0]] = r
            rows = sorted(merged.values(), key=lambda r: -(r[2] + r[3] + r[4]))[:MAX_MOVES]
        positions[k] = rows
    names = {}
    for letter in 'abcde':
        path = os.path.join(ROOT, 'Tools', 'data', f'{letter}.tsv')
        for line in open(path).read().splitlines()[1:]:
            eco, name, pgn = line.split('\t')
            board = chess.Board()
            try:
                for tok in pgn.split():
                    if not tok[0].isdigit():
                        board.push_san(tok)
            except ValueError:
                continue
            names[key(board)] = name
    with open(OUT, 'w') as f:
        json.dump({'positions': positions, 'names': names}, f, separators=(',', ':'))
    print(f'{len(positions):,} positions, {len(names):,} names, {os.path.getsize(OUT) // 1024} KB')


if __name__ == '__main__':
    main()
