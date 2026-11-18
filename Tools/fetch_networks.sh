#!/bin/sh
# Downloads the two Stockfish 17 network files the app bundles.
set -e
cd "$(dirname "$0")/../BlancChess/Engine"
for n in nn-37f18f62d772 nn-1111cefa1111; do
  [ -f "$n.nnue" ] || curl -sSfL -o "$n.nnue" "https://tests.stockfishchess.org/api/nn/$n.nnue"
done
ls -la
