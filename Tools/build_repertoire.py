#!/usr/bin/env python3
"""Build Blanc Chess's two full repertoires: everything you play as White, and as Black.

* Opponent moves come from the Lichess opening explorer (club ratings 1000-1800, blitz/rapid/classical):
  every reply that real club players make often enough gets its own branch, rare ones included early on.
* Your moves: what you already play in your chess.com games (an optional Tools/habits.json of your own move counts) when Stockfish agrees,
  otherwise the best-scoring popular move, otherwise Stockfish's move.
* A position reached by a different move order is linked ("transposes") instead of being repeated.
* Every leaf gets Stockfish's continuation, so the app can show where a line leads.

    python3 Tools/build_repertoire.py            # both
    python3 Tools/build_repertoire.py white      # one side

Explorer answers are cached in Tools/.explorer-cache.json, so reruns are fast.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_PATH = os.path.join(ROOT, 'Tools', '.explorer-cache.json')
HABITS_PATH = os.path.join(ROOT, 'Tools', 'habits.json')
TABLE_PATH = os.path.join(ROOT, 'Tools', 'data', 'explorer-table.json')
OUT_DIR = os.path.join(ROOT, 'BlancChess', 'Repertoires')
STOCKFISH = '/opt/homebrew/bin/stockfish'

SPEEDS = 'blitz,rapid,classical'
RATINGS = '1000-1900 (Lichess database, 2014-15)'
DEPTH = int(os.environ.get('DEPTH', '14'))
MAX_PLY = int(os.environ.get('MAX_PLY', '20'))
MIN_REACH = float(os.environ.get('MIN_REACH', '0.0025'))   # stop once under 0.25% of your games get here
MIN_GAMES = 40
TRAP_SHARE = 0.007
TRAP_GAIN = 150
HABIT_MIN = 5            # games before a habit counts
HABIT_MAX_LOSS = 45      # centipawns a habit may give away vs the best move
PIECE_VALUE = {'p': 1, 'n': 3, 'b': 3, 'r': 5, 'q': 9, 'k': 0}


def reply_rule(ply):
    """(minimum share, maximum replies) for the opponent at this ply (0-based count of moves so far).
    Early on, almost everything people actually play gets an answer."""
    if ply <= 6:
        return 0.012, 12
    if ply <= 10:
        return 0.035, 6
    return 0.08, 4


class Stockfish:
    def __init__(self):
        self.p = subprocess.Popen([STOCKFISH], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.send('uci'); self.wait('uciok')
        self.send(f'setoption name Threads value {max(1, (os.cpu_count() or 4) - 2)}')
        self.send('setoption name Hash value 1024')
        self.send('isready'); self.wait('readyok')
        self.memo = {}

    def send(self, s):
        self.p.stdin.write(s + '\n'); self.p.stdin.flush()

    def wait(self, token):
        out = []
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError('stockfish exited')
            line = line.strip()
            out.append(line)
            if line.startswith(token):
                return out

    def position(self, moves):
        self.send('position startpos' + (' moves ' + ' '.join(moves) if moves else ''))

    def fen(self, moves):
        self.position(moves)
        self.send('d')
        for line in self.wait('Checkers'):
            if line.startswith('Fen: '):
                return line[5:]
        raise RuntimeError('no fen')

    def analyse(self, moves, depth=None, multipv=1):
        """[(cp from White's side, pv)] best first. Mate = +-10000."""
        depth = depth or DEPTH
        key = (tuple(moves), depth, multipv)
        if key in self.memo:
            return self.memo[key]
        self.send(f'setoption name MultiPV value {multipv}')
        self.position(moves)
        self.send(f'go depth {depth}')
        lines = {}
        for line in self.wait('bestmove'):
            if not line.startswith('info') or ' pv ' not in line or ' score ' not in line:
                continue
            t = line.split()
            k = int(t[t.index('multipv') + 1]) if 'multipv' in t else 1
            si = t.index('score')
            kind, val = t[si + 1], int(t[si + 2])
            cp = val if kind == 'cp' else (10000 if val > 0 else -10000)
            lines[k] = (cp, t[t.index('pv') + 1:])
        black = len(moves) % 2 == 1
        res = [((-cp if black else cp), pv) for k, (cp, pv) in sorted(lines.items())]
        if not res:  # mate or stalemate on the board
            res = [(0, [])]
        self.memo[key] = res
        return res


CASTLE = {'e1h1': 'e1g1', 'e1a1': 'e1c1', 'e8h8': 'e8g8', 'e8a8': 'e8c8'}


def fix_castle(uci, san):
    return CASTLE.get(uci, uci) if san.startswith('O-O') else uci


class Explorer:
    """Club-game move counts from Tools/data/explorer-table.json (built by build_explorer.py from the
    free Lichess database), in the shape the old Lichess explorer API returned."""

    def __init__(self):
        import chess
        self.chess = chess
        with open(TABLE_PATH) as f:
            self.table = json.load(f)
        self.names = {}
        for letter in 'abcde':
            path = os.path.join(ROOT, 'Tools', 'data', f'{letter}.tsv')
            if not os.path.exists(path):
                continue
            for line in open(path).read().splitlines()[1:]:
                eco, name, pgn = line.split('\t')
                board = chess.Board()
                try:
                    for tok in pgn.split():
                        if not tok[0].isdigit():
                            board.push_san(tok)
                except ValueError:
                    continue
                self.names[board.epd()] = name
        self.cache = {}
        self.fetched = 0

    def save(self):
        pass

    def get(self, moves):
        key = ','.join(moves)
        if key in self.cache:
            return self.cache[key]
        board = self.chess.Board()
        sans = []
        for u in moves:
            mv = self.chess.Move.from_uci(u)
            sans.append(board.san(mv).rstrip('+#'))
            board.push(mv)
        counts = self.table.get(' '.join(sans), {})
        out = {'white': 0, 'draws': 0, 'black': 0, 'moves': []}
        for san, (w, d, b) in sorted(counts.items(), key=lambda kv: -sum(kv[1])):
            try:
                mv = board.parse_san(san)
            except ValueError:
                continue
            uci = mv.uci()
            full_san = board.san(mv)
            board.push(mv)
            name = self.names.get(board.epd())
            board.pop()
            m = {'uci': fix_castle(uci, full_san), 'san': full_san, 'white': w, 'draws': d, 'black': b}
            if name:
                m['opening'] = {'name': name}
            out['moves'].append(m)
            out['white'] += w; out['draws'] += d; out['black'] += b
        self.cache[key] = out
        return out


def total(d):
    return d['white'] + d['draws'] + d['black']


def material(fen, color):
    score = 0
    for ch in fen.split()[0]:
        if ch.lower() in PIECE_VALUE:
            v = PIECE_VALUE[ch.lower()]
            score += v if (ch.isupper() == (color == 'w')) else -v
    return score


class Builder:
    def __init__(self, spec, sf, ex, habits):
        self.spec = spec
        self.sf = sf
        self.ex = ex
        self.me = spec['color']
        self.overrides = spec.get('overrides', {})
        self.notes = spec.get('notes', {})
        self.habits = habits.get(self.me, {})
        self.seen = {}     # position key -> path id, for transpositions
        self.count = 0
        self.started = time.time()

    def mine(self, cp):
        return cp if self.me == 'w' else -cp

    def poskey(self, path):
        return ' '.join(self.sf.fen(path).split()[:4])

    def node(self, path, move, parent_data):
        games = total(move) if 'white' in move else 0
        parent_total = total(parent_data) if parent_data else 0
        n = {'uci': move['uci'], 'san': move['san'], 'ply': len(path), 'games': games, 'fen': self.fen_of(path),
             'share': round(games / parent_total, 4) if parent_total else 0,
             'eval': self.sf.analyse(path)[0][0], 'children': []}
        if games:
            n['results'] = [round(move['white'] / games, 3), round(move['draws'] / games, 3),
                            round(move['black'] / games, 3)]
        if move.get('opening'):
            n['opening'] = move['opening']['name']
        key = ','.join(path)
        if key in self.notes:
            n['note'] = self.notes[key]
        self.count += 1
        if self.count % 50 == 0:
            mins = (time.time() - self.started) / 60
            print(f'  {self.spec["id"]}: {self.count} positions, {self.ex.fetched} fetched, {mins:.1f} min', flush=True)
        return n

    def fen_of(self, path):
        b = self.ex.chess.Board()
        for u in path:
            b.push(self.ex.chess.Move.from_uci(u))
        return b.fen(en_passant='fen')

    def san_path(self, path):
        """SAN of each move on the path, from the explorer cache (for matching habits)."""
        out = []
        for i in range(len(path)):
            data = self.ex.get(path[:i])
            m = next((m for m in data['moves'] if m['uci'] == path[i]), None)
            if not m:
                return None
            out.append(m['san'].rstrip('+#'))
        return out

    def from_moves(self, moves, uci, path):
        m = next((m for m in moves if m['uci'] == uci), None)
        return m or {'uci': uci, 'san': self.san_of(path, uci)}

    def san_of(self, path, uci):
        data = self.ex.get(path + [uci])
        return uci if not data else uci  # the app turns UCI into SAN on load

    def choose_my_move(self, path, data):
        key = ','.join(path)
        moves = data['moves'] if data else []
        best_cp, best_pv = self.sf.analyse(path)[0]
        if not best_pv:
            return None, None
        if key in self.overrides:
            return self.from_moves(moves, self.overrides[key], path), 'theory'
        # 1. Your habit, if it's sound.
        sp = self.san_path(path)
        if sp is not None:
            h = self.habits.get(' '.join(sp))
            if h:
                san, n = max(h.items(), key=lambda kv: kv[1])
                if n >= HABIT_MIN and n / sum(h.values()) >= 0.5:
                    m = next((m for m in moves if m['san'].rstrip('+#') == san), None)
                    if m:
                        cp = self.mine(self.sf.analyse(path + [m['uci']])[0][0])
                        if self.mine(best_cp) - cp <= HABIT_MAX_LOSS:
                            return m, 'yours'
        # 2. The best-scoring popular move, if it's close to Stockfish's.
        t = total(data) if data else 0
        cands = [m for m in moves if t and total(m) / t >= 0.05][:4]
        if cands:
            scored = sorted(((self.mine(self.sf.analyse(path + [m['uci']])[0][0]), m) for m in cands),
                            key=lambda x: -x[0])
            if self.mine(best_cp) - scored[0][0] <= 50:
                return scored[0][1], 'popular'
        # 3. Stockfish.
        return self.from_moves(moves, best_pv[0], path), 'engine'

    def sacrifice(self, path, uci):
        before = material(self.sf.fen(path), self.me)
        after = self.sf.analyse(path + [uci])
        if not after[0][1]:
            return False
        reply = after[0][1][0]
        mat = material(self.sf.fen(path + [uci, reply]), self.me)
        if before - mat < 2 or self.mine(after[0][0]) < 80:
            return False
        if len(after[0][1]) >= 2:   # taking straight back is a trade, not a sacrifice
            mat2 = material(self.sf.fen(path + [uci, reply, after[0][1][1]]), self.me)
            if before - mat2 < 2:
                return False
        return True

    def leaf(self, path, node):
        node['continuation'] = self.sf.analyse(path, depth=DEPTH + 2)[0][1][:8]

    def transposed(self, path, node):
        k = self.poskey(path)
        if k in self.seen and self.seen[k] != ','.join(path):
            node['transposes'] = self.seen[k]
            return True
        self.seen[k] = ','.join(path)
        return False

    def expand_mine(self, path, node, reach):
        if self.transposed(path, node):
            return
        data = self.ex.get(path)
        move, why = self.choose_my_move(path, data)
        if move is None:
            return
        child = self.node(path + [move['uci']], move, data)
        child['why'] = why
        child['reach'] = round(reach, 5)
        if len(path) >= 4 and self.sacrifice(path, move['uci']):
            child['brilliant'] = True
        node['children'].append(child)
        self.expand_theirs(path + [move['uci']], child, reach)

    def expand_theirs(self, path, node, reach):
        if self.transposed(path, node):
            return
        data = self.ex.get(path)
        t = total(data)
        if len(path) >= MAX_PLY or t < MIN_GAMES or reach < MIN_REACH:
            self.leaf(path, node)
            return
        before = self.mine(node.get('eval', self.sf.analyse(path)[0][0]))
        min_share, max_n = reply_rule(len(path))
        replies = [m for m in data['moves'] if total(m) / t >= min_share][:max_n]
        for m in data['moves']:
            if m in replies or not (TRAP_SHARE <= total(m) / t):
                continue
            after = self.mine(self.sf.analyse(path + [m['uci']])[0][0])
            if after - before >= TRAP_GAIN and after >= TRAP_GAIN:
                replies.append(m)
        if not replies:
            self.leaf(path, node)
            return
        for m in replies:
            share = total(m) / t
            child = self.node(path + [m['uci']], m, data)
            child['reach'] = round(reach * share, 5)
            gain = self.mine(child['eval']) - before
            if gain >= TRAP_GAIN and self.mine(child['eval']) >= TRAP_GAIN:
                child['trap'] = True
            node['children'].append(child)
            if reach * share < MIN_REACH:
                # Rare: learn the right answer, then stop.
                self.expand_mine_short(path + [m['uci']], child, reach * share)
            else:
                self.expand_mine(path + [m['uci']], child, reach * share)

    def expand_mine_short(self, path, node, reach):
        if self.transposed(path, node):
            return
        data = self.ex.get(path)
        move, why = self.choose_my_move(path, data)
        if move is None:
            return
        child = self.node(path + [move['uci']], move, data)
        child['why'] = why
        child['reach'] = round(reach, 5)
        self.leaf(path + [move['uci']], child)
        node['children'].append(child)

    def build(self):
        data = self.ex.get([])
        root = {'uci': '', 'san': '', 'ply': 0, 'games': total(data), 'share': 1, 'eval': self.sf.analyse([])[0][0],
                'fen': self.fen_of([]),
                'children': [], 'reach': 1.0}
        if self.me == 'w':
            self.expand_mine([], root, 1.0)
        else:
            self.expand_theirs([], root, 1.0)
        return {'id': self.spec['id'], 'name': self.spec['name'], 'color': self.me, 'summary': self.spec['summary'],
                'source': f'Lichess explorer ({SPEEDS}; ratings {RATINGS}) + Stockfish depth {DEPTH} + your chess.com games',
                'built': time.strftime('%Y-%m-%d'), 'tree': root}


P = 'e2e4,e7e5,g1f3,b8c6,c2c3'
C = 'e2e4,c7c6'
WHITE = {
    'id': 'white', 'name': 'White', 'color': 'w',
    'summary': '1.e4, with the Ponziani against 1...e5 2.Nf3 Nc6.',
    'overrides': {
        '': 'e2e4',
        'e2e4,e7e5': 'g1f3',
        'e2e4,e7e5,g1f3,b8c6': 'c2c3',
        P + ',g8f6': 'd2d4',
        P + ',g8f6,d2d4,f6e4': 'd4d5',
        P + ',g8f6,d2d4,e5d4': 'e4e5',
        P + ',d7d5': 'd1a4',
        P + ',f8c5': 'd2d4',
        P + ',d7d6': 'd2d4',
        P + ',f7f5': 'd2d4',
    },
    'notes': {
        'e2e4': 'Take the centre and open lines for your queen and bishop.',
        'e2e4,e7e5,g1f3': 'Develop with a threat: the e5 pawn is attacked.',
        P: 'The Ponziani. c3 prepares d4 and takes d4 away from the c6 knight.',
        P + ',g8f6': 'The most common reply. Black hits e4 at once.',
        P + ',g8f6,d2d4': 'This is what c3 was for. Don’t defend e4: open the centre.',
        P + ',g8f6,d2d4,f6e4': 'Black grabs the pawn. Now you gain time on the knights.',
        P + ',g8f6,d2d4,f6e4,d4d5': 'Kick the c6 knight first; e5 falls next.',
        P + ',g8f6,d2d4,e5d4,e4e5': 'Gain space and chase the f6 knight.',
        P + ',f8c5,d2d4': 'Hit the bishop and grab the centre with tempo.',
        P + ',d7d5,d1a4': 'Pin the c6 knight. Bb5 next piles on.',
        P + ',d7d6,d2d4': 'Take the centre anyway; Black is passive.',
        P + ',f7f5,d2d4': 'Open the centre while Black’s king is loose.',
    },
}
BLACK = {
    'id': 'black', 'name': 'Black', 'color': 'b',
    'summary': 'The Caro-Kann against 1.e4, and the same ...c6 and ...d5 setup against everything else.',
    'overrides': {
        'e2e4': 'c7c6', 'd2d4': 'c7c6', 'c2c4': 'c7c6', 'g1f3': 'c7c6', 'e2e3': 'c7c6',
        'g2g3': 'c7c6', 'b2b3': 'c7c6', 'b1c3': 'c7c6', 'f2f4': 'd7d5', 'b2b4': 'e7e5',
        C + ',d2d4': 'd7d5', C + ',b1c3': 'd7d5', C + ',g1f3': 'd7d5', C + ',f1c4': 'd7d5',
        C + ',d2d4,d7d5,e4e5': 'c8f5',
        C + ',d2d4,d7d5,b1c3,d5e4,c3e4': 'c8f5',
        C + ',d2d4,d7d5,b1d2,d5e4,d2e4': 'c8f5',
        C + ',d2d4,d7d5,e4d5': 'c6d5',
        C + ',d2d4,d7d5,e4d5,c6d5,c2c4': 'g8f6',
        'd2d4,c7c6,c2c4': 'd7d5', 'd2d4,c7c6,g1f3': 'd7d5', 'd2d4,c7c6,c1f4': 'd7d5',
        'c2c4,c7c6,g1f3': 'd7d5', 'c2c4,c7c6,b1c3': 'd7d5', 'g1f3,c7c6,d2d4': 'd7d5',
    },
    'notes': {
        C: 'The Caro-Kann. c6 prepares d5 and keeps your light-squared bishop free.',
        C + ',d2d4,d7d5': 'Challenge e4 straight away.',
        C + ',d2d4,d7d5,e4e5,c8f5': 'Get the bishop out before e6 locks it in.',
        C + ',d2d4,d7d5,b1c3,d5e4': 'Take on e4: the Classical.',
        C + ',d2d4,d7d5,b1c3,d5e4,c3e4,c8f5': 'Develop with tempo on the e4 knight.',
        C + ',d2d4,d7d5,e4d5,c6d5': 'Recapture with the c-pawn to keep a pawn in the centre.',
        'd2d4,c7c6': 'Same idea as your Caro-Kann: ...c6, then ...d5.',
        'd2d4,c7c6,c2c4,d7d5': 'The Slav: d5 is rock solid and your bishop stays free.',
    },
}
SPECS = {'white': WHITE, 'black': BLACK}


def main():
    wanted = sys.argv[1:] or list(SPECS)
    os.makedirs(OUT_DIR, exist_ok=True)
    habits = json.load(open(HABITS_PATH)) if os.path.exists(HABITS_PATH) else {}
    sf = Stockfish()
    ex = Explorer()
    try:
        for rid in wanted:
            print(f'Building {rid}…', flush=True)
            b = Builder(SPECS[rid], sf, ex, habits)
            out = b.build()
            path = os.path.join(OUT_DIR, f'{rid}.json')
            with open(path, 'w') as f:
                json.dump(out, f, separators=(',', ':'))
            print(f'Wrote {rid}.json: {b.count} positions, {os.path.getsize(path) // 1024} KB', flush=True)
    finally:
        ex.save()


if __name__ == '__main__':
    main()
