#!/bin/bash
# Compile `plume` et `plume-pill`.
#
# Ce script est autonome : il n'a besoin ni du depot Plume d'origine, ni de
# reseau. Les sources portees depuis macOS sont dans sources/ (voir
# portage/linux_port.py pour la liste exacte des retouches et leur raison).
#
# Usage :
#   ./build.sh              mise au point
#   ./build.sh release      optimise, avec la bibliotheque Swift embarquee
set -e
cd "$(dirname "$0")"

CONFIG="debug"
STATIC=""
if [ "$1" = "release" ]; then
  CONFIG="release"
  # -static-stdlib embarque libswiftCore, libFoundation, libdispatch…
  # Sans lui, le binaire reclame la toolchain Swift installee (146 Mo) juste
  # pour demarrer. Mesure : 81 Mo lies statiquement, ldd ne montre plus une
  # seule libswift*.
  STATIC="-Xswiftc -static-stdlib"
fi

if ! command -v swift >/dev/null; then
  echo "Swift est requis : sudo apt install swiftlang (voir le README)" >&2
  exit 1
fi

swift build -c "$CONFIG" $STATIC 2>&1 | grep -E "error:|warning: .*unused|Build complete" | head -20

# La pastille, en C contre GTK4. Facultative : sans GTK4, la dictee marche
# quand meme, elle est seulement muette visuellement.
if pkg-config --exists gtk4 2>/dev/null; then
  mkdir -p .build
  gcc pastille/plume-pill.c -o .build/plume-pill \
      $(pkg-config --cflags --libs gtk4) \
      $(pkg-config --cflags --libs gtk4-layer-shell-0 2>/dev/null) \
      -lX11 -lm 2>&1 | grep -E " error" | head -5
  echo "pastille  : .build/plume-pill"
else
  echo "pastille  : GTK4 absent — sudo apt install libgtk-4-dev (facultatif)"
fi

echo ""
echo "binaire   : $(pwd)/.build/$CONFIG/plume"
