#!/bin/bash
# Plume pour Linux — installation.
#
# Ce script fait trois choses, et ne touche a rien d'autre :
#   1. verifie les outils systeme (parecord, xdotool) et propose de les installer
#   2. compile whisper-server (whisper.cpp), le meme moteur que sur macOS
#   3. installe le binaire `plume` et sa configuration
#
# Rien n'est ecrit hors de : ~/bin, ~/.config/plume, ~/.local/share/plume
# (et le modele Whisper, ~550 Mo, dans ~/.local/share/plume/models).

set -euo pipefail

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
RED=$'\033[31m'; RESET=$'\033[0m'

say()  { printf "%s\n" "$*"; }
ok()   { printf "%s✓%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
die()  { printf "%s✗%s %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }

say ""
say "${BOLD}Plume pour Linux${RESET}"
say "${DIM}La dictee locale, en francais, declenchee par un raccourci.${RESET}"
say ""

# --- 1. Les outils ---------------------------------------------------------
say "${BOLD}1. Outils systeme${RESET}"

missing=()
command -v parecord >/dev/null || missing+=(pulseaudio-utils)
command -v xdotool  >/dev/null || missing+=(xdotool)
command -v cmake    >/dev/null || missing+=(cmake)
command -v git      >/dev/null || missing+=(git)

if [ ${#missing[@]} -gt 0 ]; then
  say "  Il manque : ${missing[*]}"
  if [ -t 0 ]; then
    read -r -p "  Les installer avec apt ? [O/n] " answer
    case "${answer:-o}" in
      o|O|y|Y|"")
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}" || die "installation impossible"
        ;;
      *) die "installe-les puis relance ce script" ;;
    esac
  else
    die "installe-les puis relance : sudo apt install ${missing[*]}"
  fi
fi
ok "parecord, xdotool, cmake, git"

# --- 2. Le moteur ----------------------------------------------------------
say ""
say "${BOLD}2. Moteur whisper-server${RESET}"
say "${DIM}Le meme que sur macOS : whisper.cpp compile en serveur local.${RESET}"

BIN="$HOME/.local/bin"
MODELS="$HOME/.local/share/plume/models"
mkdir -p "$BIN" "$MODELS" "$HOME/.cache/plume"

if [ ! -x "$BIN/whisper-server" ]; then
  BUILD="$HOME/.cache/plume/whisper.cpp"
  if [ ! -d "$BUILD" ]; then
    say "  Recuperation de whisper.cpp (v1.9.5)…"
    git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git "$BUILD" >/dev/null 2>&1 \
      || die "clone impossible"
  fi
  say "  Compilation… (quelques minutes la premiere fois)"
  cmake -S "$BUILD" -B "$BUILD/build" \
        -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_SDL2=OFF \
        -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$BUILD/build" --target whisper-server -j "$(nproc)" >/dev/null
  cp "$BUILD/build/bin/whisper-server" "$BIN/whisper-server"
fi
ok "whisper-server dans $BIN"

MODEL="$MODELS/ggml-large-v3-turbo-q5_0.bin"
if [ ! -f "$MODEL" ]; then
  say "  Telechargement du modele Whisper Turbo compact (548 Mo)…"
  curl -fL --progress-bar -o "$MODEL.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"
  EXPECTED="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
  ACTUAL="$(sha256sum "$MODEL.part" | cut -d' ' -f1)"
  [ "$ACTUAL" = "$EXPECTED" ] || { rm -f "$MODEL.part"; die "le modele telecharge est corrompu (sha256 different)"; }
  mv "$MODEL.part" "$MODEL"
fi
ok "modele Whisper ($(du -h "$MODEL" | cut -f1))"

# --- 3. Le binaire et sa configuration ------------------------------------
say ""
say "${BOLD}3. Plume${RESET}"

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$HERE/.build/release/plume" ]; then
  install -m 755 "$HERE/.build/release/plume" "$BIN/plume"
  ok "plume dans $BIN"
else
  # Pas de binaire livraison : on compile ici. C'est aussi ce qui permet a
  # celui qui installe de lire exactement ce qui tourne.
  command -v swift >/dev/null || die "Swift est requis : sudo apt install swiftlang (voir le README)"
  say "  Compilation de Plume…"
  ( cd "$HERE" && swift build -c release ) >/dev/null 2>&1 \
    || die "la compilation a echoue : lance \`swift build -c release\` dans $HERE pour voir pourquoi"
  install -m 755 "$HERE/.build/release/plume" "$BIN/plume"
  ok "plume compile et installe dans $BIN"
fi

CONFIG="$HOME/.config/plume"
mkdir -p "$CONFIG"
if [ ! -f "$CONFIG/local.json" ]; then
  cat > "$CONFIG/local.json" <<EOF
{
  "whisper": {
    "binary": "$BIN/whisper-server",
    "model": "$MODELS/ggml-large-v3-turbo-q5_0.bin"
  }
}
EOF
  ok "configuration dans $CONFIG/local.json"
else
  ok "configuration deja presente (gardee telle quelle)"
fi

# --- 4. Le moteur demarre tout seul ---------------------------------------
say ""
say "${BOLD}4. Demarrage automatique du moteur${RESET}"
say "${DIM}Un service utilisateur : le moteur charge a l'ouverture de session.${RESET}"

mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/plume-engine.service" <<EOF
[Unit]
Description=Plume — moteur whisper-server
After=default.target

[Service]
ExecStart=$BIN/whisper-server -m $MODELS/ggml-large-v3-turbo-q5_0.bin --host 127.0.0.1 --port 8090 -t 4
Restart=on-failure
Nice=10

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now plume-engine.service 2>/dev/null \
  && ok "service plume-engine actif" \
  || warn "systemd utilisateur indisponible : lance le moteur a la main (voir README)"

# --- 5. Verifier ----------------------------------------------------------
say ""
say "${BOLD}5. Verification${RESET}"
sleep 2
if "$BIN/plume" check 2>&1 | grep -q "port"; then
  "$BIN/plume" check
fi

say ""
ok "Plume est installe."
say ""
say "  ${BOLD}Essayer :${RESET}  $BIN/plume listen"
say "  ${BOLD}Raccourci :${RESET}  assigne \`$BIN/plume trigger\` a une touche (voir README)"
say ""
