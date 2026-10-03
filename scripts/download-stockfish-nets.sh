#!/bin/sh
# Downloads the two Stockfish neural network files the app bundles.
# They are too big for GitHub, so they are not saved in git.
set -e
cd "$(dirname "$0")/../ChessApp/Engine"
for net in nn-1111cefa1111 nn-37f18f62d772; do
  if [ ! -f "$net.nnue" ]; then
    echo "Downloading $net.nnue..."
    curl -fL -o "$net.nnue" "https://tests.stockfishchess.org/api/nn/$net.nnue"
  fi
  # The file name contains the start of its SHA-256 fingerprint; check it matches.
  hash=$(shasum -a 256 "$net.nnue" | cut -c1-12)
  [ "nn-$hash" = "$net" ] || { echo "$net.nnue is corrupted, delete it and run again"; exit 1; }
done
echo "Stockfish networks ready."
