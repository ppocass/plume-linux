#!/bin/bash
# Plume pour Linux — installation.
#
# Rien a compiler, rien a installer de lourd : Plume arrive en binaires prets
# pour x86_64 (compiles sous Ubuntu 24.04, donc compatibles Linux Mint 22,
# Debian 12/13, Ubuntu 22.04 et au-dela). Il ne reste qu'a preparer le moteur
# whisper-server et son modele.
#
# Trois etapes, et rien d'autre :
#   1. outils systeme (parecord, xdotool, gtk4) par apt
#   2. binaires Plume depuis GitHub
#   3. moteur whisper.cpp + modele Whisper, verifie par SHA-256
#
# Rien n'est ecrit hors de : ~/.local/bin, ~/.local/share/plume, ~/.config/plume
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
VER="0.1.0"

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

if [ ${#missing[@]} -gt 0 ]; then
  say "  Il manque : ${missing[*]}"
  if [ -t 0 ]; then
    read -r -p "  Les installer avec apt ? [O/n] " answer
    case "${answer:-o}" in
      o|O|y|Y|"")
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}" || die "installation impossible"
        ;;
      *) die "installe-les puis relance ce script : sudo apt install ${missing[*]}" ;;
    esac
  else
    die "installe-les puis relance : sudo apt install ${missing[*]}"
  fi
fi
ok "parecord, xdotool, cmake, git, gcc, gtk4"

# --- 2. Plume --------------------------------------------------------------
say ""
say "${BOLD}2. Plume${RESET}"
say "${DIM}Binaires prets, compiles pour x86_64 (Ubuntu 24.04 et au-dela).${RESET}"

mkdir -p "$BIN" "$MODELS" "$HOME/.cache/plume"

install_binary() {
  local name="$1"
  # 1. a cote du script (depot clone avec les binaires), 2. GitHub, 3. compile
  if [ -x "$HERE/bin/$name" ]; then
    install -m 755 "$HERE/bin/$name" "$BIN/$name"
    return 0
  fi
  local url="https://github.com/ppocass/plume-linux/releases/download/v$VER/$name.gz"
  if curl -fsSL --retry 3 --retry-delay 3 -o "$BIN/$name.gz" "$url" 2>/dev/null; then
    gzip -dc "$BIN/$name.gz" > "$BIN/$name"
    rm -f "$BIN/$name.gz"
    chmod 755 "$BIN/$name"
    # Un binaire tronque ne s execute pas. On verifie qu'il s'agit bien d'un
    # ELF x86-64 complet — pas en le lançant : `plume-pill` n'a pas de --help,
    # il se lance et attend sur son entree standard.
    head -c 4 "$BIN/$name" | grep -q $'\x7fELF' || { rm -f "$BIN/$name"; return 1; }
    if [ "$name" = "plume" ]; then
      "$BIN/$name" --help >/dev/null 2>&1 || { rm -f "$BIN/$name"; return 1; }
    fi
    return 0
  fi
  return 1
}

if install_binary plume; then
  ok "plume dans $BIN/plume"
else
  warn "telechargement impossible : on compile sur place (il faut Swift)"
  if [ -x "$HERE/build.sh" ] && command -v swift >/dev/null; then
    ( cd "$HERE" && ./build.sh release ) || die "la compilation a echoue"
    install -m 755 "$HERE/.build/release/plume" "$BIN/plume"
    ok "plume compile et installe"
  else
    die "Swift est requis pour compiler : voir le README"
  fi
fi

if install_binary plume-pill; then
  ok "plume-pill dans $BIN/plume-pill"
else
  warn "pastille non installee : la dictee marchera sans l'indicateur visuel"
fi

# --- 3. Le moteur ----------------------------------------------------------
say ""
say "${BOLD}3. Moteur whisper-server${RESET}"
say "${DIM}Le meme que sur macOS : whisper.cpp, en serveur local.${RESET}"

if [ ! -x "$BIN/whisper-server" ]; then
  BUILD="$HOME/.cache/plume/whisper.cpp"
  if [ ! -d "$BUILD" ]; then
    say "  Recuperation de whisper.cpp (v1.9.5)…"
    git clone --depth 1 --branch v1.9.5 -q https://github.com/ggml-org/whisper.cpp.git "$BUILD" \
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

MODEL="$MODELS/ggml-large-v3-turbo-q5_0.bin"
SHA="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
if [ ! -f "$MODEL" ]; then
  say "  Telechargement du modele Whisper Turbo compact (548 Mo)…"
  curl -fL --progress-bar -o "$MODEL.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin" \
    || { rm -f "$MODEL.part"; die "telechargement impossible"; }
  actual="$(sha256sum "$MODEL.part" | cut -d' ' -f1)"
  [ "$actual" = "$SHA" ] || { rm -f "$MODEL.part"; die "modele corrompu (sha256 different)"; }
  mv "$MODEL.part" "$MODEL"
fi
ok "modele Whisper verifie ($(du -h "$MODEL" | cut -f1))"

# --- 4. Configuration ------------------------------------------------------
say ""
say "${BOLD}4. Configuration${RESET}"

# Le port : 8090 est celui du catalogue Plume, souvent deja pris.
PORT=8090
if command -v ss >/dev/null && ss -lptn 2>/dev/null | grep -q ":8090 "; then
  PORT=8091
  warn "le port 8090 est deja pris : le moteur prendra $PORT"
fi

mkdir -p "$CONFIG"
if [ ! -f "$CONFIG/local.json" ]; then
  cat > "$CONFIG/local.json" <<EOF
{
  "whisper": {
    "binary": "$BIN/whisper-server",
    "model": "$MODEL"
  },
  "enginePort": $PORT
}
EOF
  ok "configuration dans $CONFIG/local.json (port $PORT)"
else
  ok "configuration deja presente (gardee telle quelle)"
fi

# --- 5. Le PATH ------------------------------------------------------------
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    warn "$BIN n'est pas dans ton PATH : la commande « plume » serait introuvable."
    warn "  Ajoute cette ligne a la fin de ~/.bashrc, puis rouvre le terminal :"
    warn "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

# --- 6. Verifier -----------------------------------------------------------
say ""
say "${BOLD}5. Verification${RESET}"
"$BIN/plume" check || true

say ""
ok "Plume est installe."
say ""
say "  ${BOLD}Essayer :${RESET}      $BIN/plume listen"
say "  ${BOLD}Raccourci :${RESET}    assigne « $BIN/plume trigger » a une touche"
say "                   (Parametres > Clavier > Raccourcis, voir le README)"
say "  ${BOLD}Modeles :${RESET}      $BIN/plume models"
say ""
say "  ${DIM}Le moteur se lance tout seul au premier usage.${RESET}"
say ""
