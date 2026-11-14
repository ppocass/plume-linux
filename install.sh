#!/bin/bash
# Plume pour Linux — installation.
#
# Ce script fait quatre choses, et rien d'autre :
#   1. installe les outils systeme manquants (parecord, xdotool, gtk4)
#   2. compile plume et plume-pill
#   3. compile whisper-server et telecharge le modele Whisper
#   4. installe dans ~/.local/bin, avec le service du moteur
#
# Rien n'est ecrit hors de : ~/.local/bin, ~/.local/share/plume,
# ~/.config/plume, ~/.config/systemd/user (et ~/.cache/plume pour la compilation).

set -euo pipefail

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
RED=$'\033[31m'; RESET=$'\033[0m'
say()  { printf "%s\n" "$*"; }
ok()   { printf "%s✓%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
die()  { printf "%s✗%s %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
DATA="$HOME/.local/share/plume"
MODELS="$DATA/models"
CONFIG="$HOME/.config/plume"

say ""
say "${BOLD}Plume pour Linux${RESET}"
say "${DIM}Dictee locale, en francais, declenchee par un raccourci.${RESET}"
say ""

# --- 1. Les outils ---------------------------------------------------------
say "${BOLD}1. Outils systeme${RESET}"

missing=()
command -v parecord >/dev/null || missing+=(pulseaudio-utils)
command -v xdotool  >/dev/null || missing+=(xdotool)
command -v cmake    >/dev/null || missing+=(cmake)
command -v git      >/dev/null || missing+=(git)
command -v gcc      >/dev/null || missing+=(build-essential)
pkg-config --exists gtk4 2>/dev/null || missing+=(libgtk-4-dev)
command -v swift    >/dev/null || missing+=(swiftlang)

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
ok "parecord, xdotool, cmake, git, gcc, gtk4, swift"

# pkg-config gtk4-layer-shell : facultatif (seulement pour Wayland).
if ! pkg-config --exists gtk4-layer-shell-0 2>/dev/null; then
  warn "gtk4-layer-shell absent : la pastille marchera, mais sous Wayland elle ne se placera pas en bas."
  warn "  Pour l'avoir : sudo apt install libgtk4-layer-shell-dev"
fi

# --- 2. Compiler Plume -----------------------------------------------------
say ""
say "${BOLD}2. Compilation de Plume${RESET}"

cd "$HERE"
# Le binaire est gros (81 Mo, bibliotheque Swift embarquee) : on ne le refait
# que s'il manque.
if [ ! -x "$HERE/.build/release/plume" ]; then
  say "  Compilation… (quelques minutes la premiere fois)"
  ./build.sh release 2>&1 | grep -vE "^\s*$" | tail -5 || die "la compilation a echoue : lance ./build.sh release pour voir pourquoi"
fi
[ -x "$HERE/.build/release/plume" ] || die "binaire plume absent apres compilation"
ok "plume compile"

mkdir -p "$BIN"
install -m 755 "$HERE/.build/release/plume" "$BIN/plume"
ok "plume dans $BIN/plume"

if [ -x "$HERE/.build/plume-pill" ]; then
  install -m 755 "$HERE/.build/plume-pill" "$BIN/plume-pill"
  ok "plume-pill dans $BIN/plume-pill"
else
  warn "pastille non compilee (gtk4 absent) : la dictee marchera sans elle"
fi

# --- 3. Le moteur ----------------------------------------------------------
say ""
say "${BOLD}3. Moteur whisper-server${RESET}"
say "${DIM}Le meme que sur macOS : whisper.cpp compile en serveur local.${RESET}"

mkdir -p "$MODELS" "$HOME/.cache/plume"

if [ ! -x "$BIN/whisper-server" ]; then
  BUILD="$HOME/.cache/plume/whisper.cpp"
  if [ ! -d "$BUILD" ]; then
    say "  Recuperation de whisper.cpp (v1.9.5)…"
    git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git "$BUILD" >/dev/null 2>&1 \
      || die "clone impossible"
  fi
  say "  Compilation… (quelques minutes)"
  cmake -S "$BUILD" -B "$BUILD/build" \
        -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_SDL2=OFF \
        -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$BUILD/build" --target whisper-server -j "$(nproc)" >/dev/null
  cp "$BUILD/build/bin/whisper-server" "$BIN/whisper-server"
fi
ok "whisper-server dans $BIN/whisper-server"

# Les modeles du catalogue Plume, avec leur empreinte SHA-256.
#   id                       fichier                              taille       sha256
download_model() {
  local id="$1" file="$2" sha="$3" label="$4"
  local dest="$MODELS/$file"
  if [ -f "$dest" ]; then
    ok "$label deja telecharge"
    return 0
  fi
  say "  Telechargement de $label…"
  curl -fL --progress-bar -o "$dest.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/$file" \
    || { rm -f "$dest.part"; die "telechargement impossible"; }
  local actual
  actual="$(sha256sum "$dest.part" | cut -d' ' -f1)"
  if [ "$actual" != "$sha" ]; then
    rm -f "$dest.part"
    die "le modele $label est corrompu (sha256 different : $actual)"
  fi
  mv "$dest.part" "$dest"
  ok "$label verifie ($(du -h "$dest" | cut -f1))"
}

# Le modele par defaut : Whisper Turbo compact, le meilleur rapport
# rapidite/precision en CPU (574 Mo).
download_model whisper-turbo-q5 ggml-large-v3-turbo-q5_0.bin \
  394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2 \
  "Whisper Turbo compact"

# --- 4. Configuration et service ------------------------------------------
say ""
say "${BOLD}4. Configuration${RESET}"

mkdir -p "$CONFIG"
if [ ! -f "$CONFIG/local.json" ]; then
  cat > "$CONFIG/local.json" <<EOF
{
  "whisper": {
    "binary": "$BIN/whisper-server",
    "model": "$MODELS/ggml-large-v3-turbo-q5_0.bin"
  },
  "enginePort": $PORT
}
EOF
  ok "configuration dans $CONFIG/local.json (port $PORT)"
else
  ok "configuration deja presente (gardee telle quelle)"
fi

# Le port : 8090 est le port du catalogue Plume, mais il est parfois deja pris.
PORT=8090
if command -v ss >/dev/null && ss -lptn 2>/dev/null | grep -q ":8090 "; then
  PORT=8091
  warn "le port 8090 est deja pris : le moteur prendra $PORT"
  warn "  (le port est enregistre dans la configuration, rien a faire a la main)"
fi

mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/plume-engine.service" <<EOF
[Unit]
Description=Plume — moteur whisper-server
After=default.target

[Service]
ExecStart=$BIN/whisper-server -m $MODELS/ggml-large-v3-turbo-q5_0.bin --host 127.0.0.1 --port $PORT -t 4
Restart=on-failure
Nice=10

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload 2>/dev/null || true
if systemctl --user enable --now plume-engine.service 2>/dev/null; then
  ok "service plume-engine actif (port $PORT)"
else
  warn "systemd utilisateur indisponible : lance le moteur a la main :"
  warn "  $BIN/whisper-server -m $MODELS/ggml-large-v3-turbo-q5_0.bin --port $PORT &"
fi

# --- 5. Verifier ----------------------------------------------------------
say ""
say "${BOLD}5. Verification${RESET}"
sleep 3
PLUME_PORT=$PORT "$BIN/plume" check || true

say ""
ok "Plume est installe."
say ""
say "  ${BOLD}Essayer :${RESET}        $BIN/plume listen"
say "  ${BOLD}Raccourci :${RESET}      assigne « $BIN/plume trigger » a une touche"
say "                     (Parametres > Clavier > Raccourcis, voir le README)"
say "  ${BOLD}Changer de modele :${RESET} $BIN/plume models"
say ""
