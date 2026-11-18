#!/usr/bin/env python3
"""Build Blanc Chess's opening library: one repertoire tree per popular opening, for either side.

Same machinery and JSON schema as Tools/build_repertoire.py (club move counts from
Tools/data/explorer-table.json, Stockfish for our moves, traps, transpositions and continuations),
plus a few top-level keys per pack: setup, title, family, blurb, popularity. Specs live in
Tools/library_specs.py. Unlike the personal repertoires, no habits are used.

* The setup line is always followed; opponent deviations during the setup get answers but are
  followed only `dev_plies` deep, so the app can show what the opening "could also turn into".
* Black packs only answer the setup's first White move (the French starts from 1.e4 only).
* Each pack is sized by a quick dry run (no engine) before the real build: 200-900 positions.

    Tools/.venv/bin/python Tools/build_library.py              # build missing packs, index, validate
    Tools/.venv/bin/python Tools/build_library.py worker       # same, but claims packs via lock files, so
                                                               # several workers can run side by side
    Tools/.venv/bin/python Tools/build_library.py w-italian    # (re)build one pack
    Tools/.venv/bin/python Tools/build_library.py check        # specs only: legality, note lengths
    Tools/.venv/bin/python Tools/build_library.py index        # rewrite library-index.json
    Tools/.venv/bin/python Tools/build_library.py validate     # check every pack + the index

Env: DEPTH (default 12), SF_THREADS (2), SF_HASH (128 MB), FORCE=1 rebuilds packs that exist,
LOCK_DIR (worker locks; default a folder in the system temp dir).
"""
import contextlib
import io
import json
import os
import subprocess
import sys
import time

sys.dont_write_bytecode = True          # keep Tools/ free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_repertoire as br           # noqa: E402
from library_specs import SPECS         # noqa: E402
import chess                            # noqa: E402

ROOT = br.ROOT
OUT_DIR = os.path.join(ROOT, 'BlancChess', 'Repertoires', 'library')
INDEX = 'library-index.json'
DEPTH = int(os.environ.get('DEPTH', '12'))
SF_THREADS = int(os.environ.get('SF_THREADS', '2'))
SF_HASH = int(os.environ.get('SF_HASH', '128'))
LOCK_DIR = os.environ.get('LOCK_DIR') or os.path.join(__import__('tempfile').gettempdir(), 'blanc-library-locks')
PLAN_TOL = 45            # centipawns a plan move may give away vs Stockfish's best
MIN_GAMES = 20
TARGET = (450, 850)      # dry-run node count we aim for
HARD = (200, 900)        # real build must land here
MAX_KB = 300
NOTE_MAX, BLURB_MAX = 70, 60


def reply_rule(ply):
    """(minimum share, maximum replies) for the opponent: a little narrower than the personal
    repertoires early on, so the popular lines go deeper."""
    if ply <= 6:
        return 0.025, 8
    if ply <= 10:
        return 0.04, 6
    return 0.08, 4


DEFAULTS = dict(max_ply=20, main_min=0.004, dev_min=0.03, dev_plies=6, plan_until=20, min_games=MIN_GAMES)

br.DEPTH = DEPTH         # Stockfish.analyse and Builder.leaf read the module global


# ---------------------------------------------------------------- engines

class Stockfish(br.Stockfish):
    """build_repertoire's engine with a smaller footprint (shared 8 GB machine)."""

    def __init__(self):
        self.p = subprocess.Popen([br.STOCKFISH], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.send('uci'); self.wait('uciok')
        self.send(f'setoption name Threads value {SF_THREADS}')
        self.send(f'setoption name Hash value {SF_HASH}')
        self.send('isready'); self.wait('readyok')
        self.memo = {}
        self.fens = {}

    def fen(self, moves):
        key = tuple(moves)
        if key not in self.fens:
            b = chess.Board()
            for u in moves:
                b.push(chess.Move.from_uci(u))
            self.fens[key] = b.fen()
        return self.fens[key]

    def close(self):
        try:
            self.send('quit')
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


class DryEngine:
    """Stands in for Stockfish in the sizing pass: every move is equal, the 'best' is the first legal."""

    def __init__(self):
        self.memo = {}

    def fen(self, moves):
        b = chess.Board()
        for u in moves:
            b.push(chess.Move.from_uci(u))
        return b.fen()

    def analyse(self, moves, depth=None, multipv=1):
        b = chess.Board()
        for u in moves:
            b.push(chess.Move.from_uci(u))
        first = next(iter(b.legal_moves), None)
        return [(0, [first.uci()] if first else [])]


# ---------------------------------------------------------------- specs

def board_after(ucis):
    b = chess.Board()
    for u in ucis:
        b.push(chess.Move.from_uci(u))
    return b


def san_to_uci(sans, where):
    b = chess.Board()
    out = []
    for s in sans.split():
        try:
            mv = b.parse_san(s)
        except ValueError as e:
            raise SystemExit(f'{where}: illegal move {s!r} in {sans!r} ({e})')
        out.append(mv.uci())
        b.push(mv)
    return out


def uci_move(path, san, where):
    b = board_after(path)
    try:
        return b.parse_san(san).uci()
    except ValueError as e:
        raise SystemExit(f'{where}: illegal move {san!r} after {path} ({e})')


def compile_spec(spec):
    """SAN spec -> UCI paths, plus derived fields."""
    s = dict(DEFAULTS)
    s.update(spec)
    sid = s['id']
    s['setup_ucis'] = [san_to_uci(x, sid) for x in [s['setup']] + s.get('also', [])]
    s['name'] = s['title']
    me_white = s['color'] == 'w'
    over = {}
    for setup in s['setup_ucis']:
        if (len(setup) % 2 == 1) != me_white:
            raise SystemExit(f'{sid}: setup {setup} must end with our move')
        for i, u in enumerate(setup):
            if (i % 2 == 0) == me_white:
                over[','.join(setup[:i])] = u
    for k, v in s.get('overrides', {}).items():
        path = san_to_uci(k, sid)
        if (len(path) % 2 == 0) != me_white:
            raise SystemExit(f'{sid}: override at {k!r} is not our move')
        over[','.join(path)] = uci_move(path, v, sid)
    s['over'] = over
    s['note_paths'] = {','.join(san_to_uci(k, sid)): v for k, v in s.get('notes', {}).items()}
    for k, v in s.get('notes', {}).items():
        if len(v) > NOTE_MAX:
            raise SystemExit(f'{sid}: note too long ({len(v)}): {k!r}: {v!r}')
    if len(s['blurb']) > BLURB_MAX:
        raise SystemExit(f'{sid}: blurb too long ({len(s["blurb"])})')
    return s


# ---------------------------------------------------------------- builder

class LibBuilder(br.Builder):
    def __init__(self, spec, sf, ex, scale=1.0, quiet=False):
        super().__init__({'id': spec['id'], 'color': spec['color'], 'overrides': spec['over'],
                          'notes': spec['note_paths']}, sf, ex, {})
        self.s = spec
        self.setups = spec['setup_ucis']
        self.plan = spec.get('plan') or []
        self.quiet = quiet
        self.used_over, self.used_notes = set(), set()
        # The taught main lines: every position on the way to a note or an override is followed
        # whatever its reach, so the coach's lines always make it into the pack.
        self.spine = {}     # prefix -> length of the longest taught line through it
        for k in list(spec['note_paths']) + [p + (',' if p else '') + u for p, u in spec['over'].items()]:
            parts = k.split(',')
            for i in range(len(parts) + 1):
                pre = ','.join(parts[:i])
                self.spine[pre] = max(self.spine.get(pre, 0), len(parts))
        # Share of games (from our side's start) that reach the main setup position.
        self.setup_reach = self.reach_of(self.setups[0])
        self.main_abs = spec['main_min'] * scale * self.setup_reach
        self.dev_abs = spec['dev_min'] * scale * self.setup_reach

    # -- where are we?
    def reach_of(self, path):
        r = 1.0
        for i, u in enumerate(path):
            theirs = (i % 2 == 0) == (self.me == 'b')
            if not theirs or (self.me == 'b' and i == 0):
                continue
            d = self.ex.get(path[:i])
            m = next((m for m in d['moves'] if m['uci'] == u), None)
            r *= br.total(m) / br.total(d) if m else 0
        return r

    def kind(self, path):
        """('setup' | 'main' | 'dev', ply of the deviating move)"""
        best = 0
        for s in self.setups:
            if path[:len(s)] == s:
                return ('main' if len(path) > len(s) else 'setup'), 0
            if s[:len(path)] == path:
                return 'setup', 0
            n = 0
            while n < min(len(s), len(path)) and s[n] == path[n]:
                n += 1
            best = max(best, n)
        return 'dev', best + 1

    def limits(self, path):
        k, dev_ply = self.kind(path)
        if k == 'dev':
            return k, min(self.s['max_ply'], dev_ply + self.s['dev_plies']), self.dev_abs
        return k, self.s['max_ply'], self.main_abs

    def on_setup_next(self, path):
        for s in self.setups:
            if len(path) < len(s) and s[:len(path)] == path:
                yield s[len(path)]

    # -- overrides of build_repertoire.Builder
    def node(self, path, move, parent_data):
        if self.quiet:
            with contextlib.redirect_stdout(io.StringIO()):
                n = super().node(path, move, parent_data)
        else:
            n = super().node(path, move, parent_data)
        key = ','.join(path)
        if key in self.notes:
            self.used_notes.add(key)
        return n

    def san_of(self, path, uci):
        return board_after(path).san(chess.Move.from_uci(uci))

    def choose_my_move(self, path, data):
        key = ','.join(path)
        if key in self.overrides:
            self.used_over.add(key)
            return super().choose_my_move(path, data)
        if self.plan and len(path) < self.s['plan_until']:
            best = self.sf.analyse(path)[0]
            if not best[1]:
                return None, None
            b = board_after(path)
            home = chess.Board()
            tried = 0
            for san in self.plan:
                try:
                    mv = b.parse_san(san)
                except ValueError:
                    continue
                if b.piece_at(mv.from_square) != home.piece_at(mv.from_square):
                    continue            # that piece has already moved
                tried += 1
                cp = self.mine(self.sf.analyse(path + [mv.uci()])[0][0])
                if self.mine(best[0]) - cp <= PLAN_TOL:
                    moves = data['moves'] if data else []
                    return self.from_moves(moves, mv.uci(), path), 'theory'
                if tried >= 2:
                    break
        return super().choose_my_move(path, data)

    def expand_theirs(self, path, node, reach):
        if self.transposed(path, node):
            return
        data = self.ex.get(path)
        t = br.total(data)
        kind, max_ply, min_reach = self.limits(path)
        setup_next = list(self.on_setup_next(path))
        nexts = list(setup_next)
        key = ','.join(path)
        nexts += [m['uci'] for m in data['moves']
                  if (key + ',' if key else '') + m['uci'] in self.spine and m['uci'] not in nexts]
        pinned = key in self.spine
        if t == 0 or (kind != 'setup' and not pinned and (len(path) >= max_ply or t < self.s['min_games'] or reach < min_reach)):
            self.leaf(path, node)
            return
        if self.me == 'b' and not path:                     # only the setup's first move
            replies = [m for m in data['moves'] if m['uci'] in setup_next]
        else:
            before = self.mine(node.get('eval', self.sf.analyse(path)[0][0]))
            min_share, max_n = reply_rule(len(path))
            if kind == 'dev':
                min_share, max_n = max(min_share, 0.05), min(max_n, 5)
            replies = [m for m in data['moves'] if br.total(m) / t >= min_share][:max_n]
            for m in data['moves']:
                if m in replies:
                    continue
                if m['uci'] in nexts:
                    replies.append(m)
                    continue
                if br.total(m) / t < br.TRAP_SHARE:
                    continue
                after = self.mine(self.sf.analyse(path + [m['uci']])[0][0])
                if after - before >= br.TRAP_GAIN and after >= br.TRAP_GAIN:
                    replies.append(m)
        if not replies:
            self.leaf(path, node)
            return
        before = self.mine(node.get('eval', 0))
        kids = []
        for m in replies:
            share = br.total(m) / t
            r = 1.0 if (self.me == 'b' and not path) else reach * share
            child = self.node(path + [m['uci']], m, data)
            child['reach'] = round(r, 5)
            gain = self.mine(child['eval']) - before
            if path and gain >= br.TRAP_GAIN and self.mine(child['eval']) >= br.TRAP_GAIN:
                child['trap'] = True
            node['children'].append(child)
            ck = (key + ',' if key else '') + m['uci']
            rank = (0, 0) if m['uci'] in setup_next else (1, -self.spine[ck]) if ck in self.spine else (2, 0)
            kids.append((rank, child, path + [m['uci']], r))
        for _, child, p, r in sorted(kids, key=lambda k: k[0]):   # setup, then taught lines: they own transpositions
            ck, _, cmin = self.limits(p)
            if ck != 'setup' and r < cmin and ','.join(p) not in self.spine:
                self.expand_mine_short(p, child, r)
            else:
                self.expand_mine(p, child, r)

    def build(self):
        data = self.ex.get([])
        root = {'uci': '', 'san': '', 'ply': 0, 'games': br.total(data), 'share': 1,
                'eval': self.sf.analyse([])[0][0], 'fen': self.fen_of([]), 'children': [], 'reach': 1.0}
        if self.me == 'w':
            self.expand_mine([], root, 1.0)
        else:
            self.expand_theirs([], root, 1.0)
        return root


# ---------------------------------------------------------------- packs

def popularity(spec, ex):
    total = 0
    for setup in spec['setup_ucis']:
        d = ex.get(setup[:-1])
        m = next((m for m in d['moves'] if m['uci'] == setup[-1]), None)
        total += br.total(m) if m else 0
    if spec['color'] == 'w':
        return total / br.total(ex.get([]))
    first = next(m for m in ex.get([])['moves'] if m['uci'] == spec['setup_ucis'][0][0])
    return total / br.total(first)


def count(tree):
    n, st = 0, [tree]
    while st:
        x = st.pop(); n += 1; st += x['children']
    return n


def setup_san(ucis):
    b, out = chess.Board(), []
    for i, u in enumerate(ucis):
        mv = chess.Move.from_uci(u)
        s = b.san(mv)
        out.append(f'{i // 2 + 1}.{s}' if i % 2 == 0 else s)
        b.push(mv)
    return ' '.join(out)


def size_scale(spec, ex):
    """Dry runs (no engine) to pick the reach scale that lands in TARGET."""
    dry = DryEngine()
    scale, seen = 1.0, {}
    for _ in range(12):
        n = count(LibBuilder(spec, dry, ex, scale, quiet=True).build())
        seen[scale] = n
        if n > TARGET[1]:
            scale *= 1.5
        elif n < TARGET[0] and scale > 0.02:
            scale /= 1.5
        else:
            break
    return scale, seen[scale]


def build_pack(spec, sf, ex):
    t0 = time.time()
    scale, est = size_scale(spec, ex)
    print(f'{spec["id"]}: scale {scale:.3f}, dry run {est} positions', flush=True)
    for attempt in range(5):
        b = LibBuilder(spec, sf, ex, scale)
        tree = b.build()
        n = count(tree)
        out = {'id': spec['id'], 'name': spec['name'], 'title': spec['title'], 'color': spec['color'],
               'family': spec['family'], 'blurb': spec['blurb'], 'setup': spec['setup_ucis'][0],
               'popularity': round(popularity(spec, ex), 5), 'summary': spec['summary'],
               'source': f'Lichess database ({br.SPEEDS}; ratings {br.RATINGS}) + Stockfish depth {DEPTH}',
               'built': time.strftime('%Y-%m-%d'), 'tree': tree}
        blob = json.dumps(out, separators=(',', ':'), ensure_ascii=False)
        kb = len(blob.encode()) / 1024
        if (n > HARD[1] or kb > MAX_KB) and attempt < 4:
            scale *= 1.4
            print(f'  {n} positions / {kb:.0f} KB: too big, rescaling to {scale:.3f}', flush=True)
            continue
        if n < HARD[0] and attempt < 4 and scale > 0.02:
            scale /= 1.4
            print(f'  {n} positions: too small, rescaling to {scale:.3f}', flush=True)
            continue
        break
    for k in set(spec['over']) - b.used_over:
        print(f'  note: override never reached: {k}', flush=True)
    for k in set(spec['note_paths']) - b.used_notes:
        print(f'  WARNING: note never placed: {k}', flush=True)
    path = os.path.join(OUT_DIR, f'{spec["id"]}.json')
    tmp = os.path.join(OUT_DIR, f'.{spec["id"]}.{os.getpid()}.tmp')
    with open(tmp, 'w') as f:
        f.write(blob)
    os.replace(tmp, path)
    print(f'Wrote {spec["id"]}.json: {n} positions, {kb:.0f} KB, popularity {out["popularity"]:.4f}, '
          f'{(time.time() - t0) / 60:.1f} min', flush=True)


def write_index():
    rows = []
    for spec in SPECS:
        path = os.path.join(OUT_DIR, f'{spec["id"]}.json')
        if not os.path.exists(path):
            continue
        d = json.load(open(path))
        rows.append({'id': d['id'], 'title': d['title'], 'color': d['color'], 'family': d['family'],
                     'blurb': d['blurb'], 'setup': d['setup'], 'setupSAN': setup_san(d['setup']),
                     'fen': board_after(d['setup']).fen(), 'popularity': d['popularity'],
                     'positions': count(d['tree']), 'sizeKB': round(os.path.getsize(path) / 1024)})
    rows.sort(key=lambda r: (r['color'] != 'w', -r['popularity']))
    tmp = os.path.join(OUT_DIR, f'.{INDEX}.{os.getpid()}.tmp')
    with open(tmp, 'w') as f:
        json.dump(rows, f, indent=1, ensure_ascii=False)
    os.replace(tmp, os.path.join(OUT_DIR, INDEX))
    print(f'Wrote {INDEX}: {len(rows)} packs', flush=True)


# ---------------------------------------------------------------- validation

NODE_KEYS = {'uci', 'san', 'ply', 'fen', 'games', 'share', 'eval', 'results', 'opening', 'note', 'why',
             'reach', 'trap', 'brilliant', 'transposes', 'continuation', 'children'}
TOP_KEYS = {'id', 'name', 'title', 'color', 'family', 'blurb', 'setup', 'popularity', 'summary', 'source',
            'built', 'tree'}


def validate_pack(d):
    errs = []
    me = d['color']
    if set(d) != TOP_KEYS:
        errs.append(f'top-level keys {sorted(set(d) ^ TOP_KEYS)}')
    if me not in ('w', 'b') or not d['id'].startswith(me + '-'):
        errs.append('bad color/id')
    if len(d['blurb']) > BLURB_MAX:
        errs.append('blurb too long')
    if not 0 < d['popularity'] <= 1:
        errs.append('popularity out of range')
    ids, links = set(), []
    st = [(d['tree'], [], chess.Board())]
    while st:
        n, path, board = st.pop()
        nid = ','.join(path)
        ids.add(nid)
        if set(n) - NODE_KEYS:
            errs.append(f'{nid}: unknown keys {set(n) - NODE_KEYS}')
        if n['ply'] != len(path) or n['fen'].split()[:4] != board.fen(en_passant='fen').split()[:4]:
            errs.append(f'{nid}: ply/fen mismatch')
        if len(n.get('note', '')) > NOTE_MAX:
            errs.append(f'{nid}: note too long')
        if n.get('transposes') is not None:
            links.append((nid, n['transposes']))
        ours = (board.turn == chess.WHITE) == (me == 'w')
        kids = n['children']
        if ours and len(kids) != 1 and not (not kids and (n.get('transposes') or board.is_game_over())):
            errs.append(f'{nid}: {len(kids)} children at our move')
        for c in kids:
            try:
                mv = chess.Move.from_uci(c['uci'])
            except ValueError:
                errs.append(f'{nid}: bad uci {c["uci"]}'); continue
            if mv not in board.legal_moves:
                errs.append(f'{nid}: illegal {c["uci"]}'); continue
            if board.san(mv) != c['san']:
                errs.append(f'{nid}: san {c["san"]} != {board.san(mv)}')
            b2 = board.copy(); b2.push(mv)
            st.append((c, path + [c['uci']], b2))
    for a, b in links:
        if b not in ids:
            errs.append(f'{a}: transposes to missing {b}')
    # setup line
    node, board = d['tree'], chess.Board()
    for i, u in enumerate(d['setup']):
        mover_white = i % 2 == 0
        if (board.turn == chess.WHITE) != mover_white:
            errs.append(f'setup ply {i}: wrong side to move')
        nxt = next((c for c in node['children'] if c['uci'] == u), None)
        if nxt is None:
            errs.append(f'setup move {u} missing at ply {i}'); break
        board.push(chess.Move.from_uci(u)); node = nxt
    if (len(d['setup']) % 2 == 1) != (me == 'w'):
        errs.append('setup does not end with our move')
    if me == 'b' and [c['uci'] for c in d['tree']['children']] != d['setup'][:1]:
        errs.append('black pack root must have only the setup first move')
    return errs


def validate():
    bad = 0
    total_kb = 0
    for spec in SPECS:
        path = os.path.join(OUT_DIR, f'{spec["id"]}.json')
        if not os.path.exists(path):
            print(f'{spec["id"]}: MISSING'); bad += 1; continue
        d = json.load(open(path))
        errs = validate_pack(d)
        total_kb += os.path.getsize(path) / 1024
        print(f'{spec["id"]}: {"ok" if not errs else str(len(errs)) + " errors"}')
        for e in errs[:10]:
            print('   ', e)
        bad += bool(errs)
    idx = json.load(open(os.path.join(OUT_DIR, INDEX)))
    want = {'id', 'title', 'color', 'family', 'blurb', 'setup', 'setupSAN', 'fen', 'popularity', 'positions',
            'sizeKB'}
    for r in idx:
        if set(r) != want:
            print(f'index {r.get("id")}: keys {set(r) ^ want}'); bad += 1
        p = os.path.join(OUT_DIR, f'{r["id"]}.json')
        if not os.path.exists(p):
            print(f'index {r["id"]}: no pack file'); bad += 1
    print(f'{len(idx)} packs in index, {total_kb / 1024:.2f} MB total, {bad} problems')
    return bad == 0


# ---------------------------------------------------------------- main

def played_share(spec, ex):
    """Share of all games that reach the setup (for build order: most-played first)."""
    n = 0
    for setup in spec['setup_ucis']:
        d = ex.get(setup[:-1])
        m = next((m for m in d['moves'] if m['uci'] == setup[-1]), None)
        n += br.total(m) if m else 0
    return n / br.total(ex.get([]))


def claim(sid):
    """Atomically claim a pack for this worker; reclaim locks left by dead workers."""
    os.makedirs(LOCK_DIR, exist_ok=True)
    lock = os.path.join(LOCK_DIR, sid + '.lock')
    for _ in range(2):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode()); os.close(fd)
            return lock
        except FileExistsError:
            try:
                os.kill(int(open(lock).read() or 0), 0)
                return None                     # a live worker has it
            except (ProcessLookupError, ValueError):
                os.remove(lock)                 # stale
            except PermissionError:
                return None
    return None


def main():
    args = sys.argv[1:]
    specs = {s['id']: compile_spec(s) for s in SPECS}
    if args == ['check']:
        print(f'{len(specs)} specs compile; notes and blurbs fit.')
        return
    if args == ['index']:
        write_index(); return
    if args == ['validate']:
        sys.exit(0 if validate() else 1)
    os.makedirs(OUT_DIR, exist_ok=True)
    worker = args == ['worker']
    if worker:
        args = []
    wanted = args or list(specs)
    for w in wanted:
        if w not in specs:
            raise SystemExit(f'unknown pack {w}')
    ex = br.Explorer()
    if not args:
        wanted.sort(key=lambda sid: -played_share(specs[sid], ex))
    sf = Stockfish()
    t0 = time.time()
    try:
        for sid in wanted:
            path = os.path.join(OUT_DIR, f'{sid}.json')
            if not args and os.path.exists(path) and not os.environ.get('FORCE'):
                print(f'{sid}: exists, skipped', flush=True)
                continue
            lock = claim(sid) if worker else None
            if worker and not lock:
                continue
            try:
                if worker and os.path.exists(path) and not os.environ.get('FORCE'):
                    continue                    # finished by another worker meanwhile
                sf.memo.clear()
                build_pack(specs[sid], sf, ex)
                write_index()
            finally:
                if lock:
                    os.remove(lock)
    finally:
        sf.close()
    print(f'Total build time {(time.time() - t0) / 60:.1f} min', flush=True)
    write_index()
    if not worker:
        validate()


if __name__ == '__main__':
    main()
