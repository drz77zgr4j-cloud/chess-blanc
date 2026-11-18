# Chess Blanc

The modern way to learn chess: learn openings with spaced repetition, review your games with
Stockfish, drill the positions you got wrong, and see where your games are won and lost.
A native SwiftUI app for iPhone and iPad by Blanc Works Ltd.

[App Store](https://apps.apple.com/app/id6836408131) ·
[Support](https://drz77zgr4j-cloud.github.io/chess-blanc/support/) ·
[Privacy](https://drz77zgr4j-cloud.github.io/chess-blanc/privacy/)

## Building

1. Open `BlancChess.xcodeproj` in Xcode (iOS 17 or later).
2. Run `Tools/fetch_networks.sh` once to download Stockfish's network files (they're not kept in git).
3. Build the `BlancChess` scheme in **Release**; Stockfish is too slow in Debug.

To sign it yourself, set your own team and bundle identifier.

## Data

- **Opening lines** come from the Lichess opening explorer and the Lichess `chess-openings` names
  (CC0), checked by Stockfish. `Tools/build_library.py` and `Tools/build_repertoire.py` rebuild them.
- **Games** are read from the public chess.com and Lichess APIs by username only. Nothing is sent
  anywhere else; there is no Chess Blanc server.

## Licence

Chess Blanc is free software under the **GNU General Public License v3** (see `LICENSE`),
because it includes Stockfish.

Third-party parts:

| Part | Author | Licence |
| --- | --- | --- |
| Stockfish 17 (via chesskit-engine) | The Stockfish developers | GPL v3 |
| chesskit-swift, chesskit-engine | chesskit-app contributors | MIT |
| Opening names (lichess-org/chess-openings) | Lichess | CC0 |
| Classic pieces | Colin M.L. Burnett | GPL v2+ |
| Merida pieces | Armando Hernandez Marroquin | GPL v2+ |
| Chessnut pieces | Alexis Luengas | Apache 2.0 |
| Fantasy, Celtic, Spatial pieces | Maurizio Monge | MIT |
| Papercut pieces | Nikolay Anzarov | CC BY 4.0 |
| Totoy pieces | Kosal Sen | CC BY 4.0 |

"Chess Blanc", "Blanc", the Blanc B and the app icon are trademarks of Blanc Works Ltd and are not
covered by the GPL; please use your own name and icon for a fork.
