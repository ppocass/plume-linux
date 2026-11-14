# Plume pour Linux

[Plume](https://github.com/ppocass/plume) est une dictée locale : on appuie sur
une touche, on parle, le texte apparaît là où est le curseur. Tout se passe sur
la machine, rien ne part dans le cloud.

Sur macOS, c'est une app native en SwiftUI. Ici, c'est **la même logique** —
barrière anti-silence, découpage aux pauses, vocabulaire, 1337, lissage —
recâblée sur ce que Linux fournit à la place des briques Apple.

**État** : ça fonctionne de bout en bout, testé sur Debian 13 en X11. C'est
une version de test, pas une version officielle.

![la pastille](pastille/apercu.png)

---

## Installation

```bash
git clone https://github.com/ppocass/plume-linux.git
cd plume-linux
./install.sh
```

**Rien à compiler pour Plume.** Il arrive en binaires prêts pour x86_64,
compilés sous Ubuntu 24.04 — donc compatibles **Linux Mint 22**, Ubuntu 22.04
et au-delà, Debian 12 et 13.

Le script fait trois choses :

1. installe les outils manquants (GTK4, parecord, xdotool) — il demande avant
2. télécharge `plume` et `plume-pill` depuis la release, et les vérifie
3. compile `whisper-server` et télécharge le modèle (548 Mo, SHA-256 vérifié)

Comptez **5 à 10 minutes**, dont l'essentiel pour whisper.cpp.

### Si tu préfères compiler toi-même

`./build.sh release` demande **Swift**. Sur Debian 13 : `sudo apt install
swiftlang`. Ailleurs, la [toolchain officielle](https://www.swift.org/install/linux/)
— **elle n'existe pas dans les dépôts de Mint 22**. Le binaire produit pèse
81 Mo, bibliothèque Swift embarquée.

## Utilisation

```bash
plume listen      # dicter : Entrée pour commencer et arrêter
plume trigger     # dicter depuis un raccourci du bureau
plume text x.wav  # transcrire un fichier WAV
plume models      # choisir un modèle, en télécharger un
plume check       # vérifier l'installation
```

### Le raccourci clavier

`plume trigger` est fait pour être lancé par un raccourci du bureau.

**XFCE** (Linux Mint) : `Paramètres > Clavier > Raccourcis d'application >
Ajouter` → commande : `plume trigger` → touche : `Super+D`, par exemple.

**GNOME** : `Paramètres > Clavier > Raccourcis personnalisés`.

Durée d'enregistrement réglable : `PLUME_SECONDS=30 plume trigger`
(15 s par défaut).

### Choisir un modèle

```bash
plume models                       # la liste
plume models download whisper-turbo   # télécharger (1,6 Go, sha256 vérifié)
plume models use whisper-turbo        # l'utiliser
```

Quatre modèles sont proposés sous Linux :

| Modèle | Taille | Pour qui |
|---|---|---|
| `whisper-turbo-q5` | 574 Mo | **par défaut**, le meilleur rapport rapidité/précision en CPU |
| `whisper-turbo` | 1,6 Go | un peu plus juste, 16 Go de RAM conseillés |
| `whisper-large-v3` | 3,1 Go | le plus précis, lent, pour une machine puissante |
| `cloud` | — | un service distant, avec votre propre clé API |

**Parakeet n'est pas proposé** : il tourne sur le Neural Engine via Core ML,
qui n'existe que sur Apple.

## La pastille

Une capsule sombre apparaît en bas de l'écran pendant la dictée, avec
**treize barres qui suivent le niveau du micro** — comme sur macOS.

- **cyan** à l'écoute (`#33D6E0`)
- **ambre** en vague pendant la transcription (`#F5A623`)
- **✓ vert** quand le texte est collé (`#5FD29A`)

Si elle n'est pas là (GTK4 absent, pas d'affichage), la dictée marche quand
même : elle est seulement muette visuellement.

## Ce qui marche, ce qui ne marche pas

**Marche** : le geste complet (touche → micro → transcription → collage),
la barrière anti-silence, le découpage aux pauses, le vocabulaire, le 1337,
le lissage par un LLM, la pastille animée, le choix du modèle.

**Ne marche pas encore** :

- **Wayland** : `xdotool` ne peut pas taper dans les autres fenêtres. Il faut
  `ydotool` (démon root) ou `wtype`. Sous X11, tout fonctionne.
- **Pas de fenêtre de réglages** : la configuration est un fichier JSON.
- **Pas de mise à jour automatique.**
- **Pas d'historique** dans l'interface (il est écrit sur disque, mais il n'y a
  pas d'écran pour le parcourir).

## Si quelque chose ne va pas

```bash
plume check        # l'état de l'installation
```

**Le port est déjà pris.** Le moteur prend un port libre à partir de 8090
(crowdsec, Docker et d'autres services l'occupent souvent). `plume` le trouve
tout seul ; pour forcer un port : `PLUME_PORT=8091 plume listen`.

**« moteur indisponible ».** Vérifiez `~/.config/plume/local.json` : les chemins
du binaire `whisper-server` et du modèle doivent exister. `plume check` les
affiche.

**La pastille ne s'affiche pas.** `sudo apt install libgtk-4-dev` puis
`./build.sh`. Sous Wayland, elle apparaît mais ne se place pas en bas sans
`libgtk4-layer-shell-dev`.

**Le raccourci ne colle rien.** Sous Wayland, c'est la limite de `xdotool`.
Sous X11, vérifiez que `xdotool` est installé (`plume check`).

## Comment c'est fait

Le portage ne réécrit rien : il donne à Linux l'équivalent de chaque brique
Apple. **27 retouches**, toutes dans `portage/linux_port.py`, avec un
commentaire par retouche :

| Sur macOS | Sous Linux |
|---|---|
| `CryptoKit` | `swift-crypto` (même API, paquet Apple, MIT) |
| `Foundation` | `FoundationNetworking` (`URLSession` y vit) |
| `mach`, `sysctl` | `/proc` (`meminfo`, `cpuinfo`, `stat`, `exe`) |
| `Security` (trousseau) | fichier en `0600` dans `~/.config/plume/keys` |
| `Combine` | déclarations vides (le code n'utilise que les marqueurs) |
| `FileManager.trashItem` | spécification XDG (`~/.local/share/Trash`) |

**Ce qui compile sans une ligne changée** : `SpeechGate`, `SpeechEngine`,
`Polisher`, `Vocabulary`, `Leet`, `History`, `ModelCatalog`, `ModelStore`,
`CloudTranscriber`, `VoiceCommands` — environ **2 300 lignes sur 8 900**.

Seule la couche qui touche au bureau est réécrite :

| macOS | Linux |
|---|---|
| `AVAudioEngine` | `parecord` (PipeWire / PulseAudio), 16 kHz mono |
| `CGEventTap` | raccourci du bureau |
| `AXUIElement` + ⌘V | `xdotool type` |
| `NSPanel` + SwiftUI | GTK4 + Xlib (X11) ou gtk4-layer-shell (Wayland) |

### Trois pièges GTK4, payés une fois

1. **GTK4 a supprimé `GTK_WINDOW_POPUP`** ; `gtk_window_new()` ne prend plus
   d'argument.
2. **`gtk4-layer-shell` est Wayland seulement** : sous X11 il refuse de
   s'initialiser et toutes ses fonctions ne font rien. On passe par Xlib.
3. **`override_redirect` doit être posé avant le map**, sinon la fenêtre
   disparaît.

### Deux pièges de fondation Swift sous Linux

1. **`URLSession` en mode téléchargement avec delegate** provoque
   `_MultiHandle deallocated with non-zero retain count` puis un abort à la
   libération. Le fichier arrive, puis le processus meurt avant de l'installer.
   Le téléchargement passe donc par `curl`.
2. **Une `static let` calculée n'est évaluée qu'une fois.** Poser un réglage
   après son premier accès n'a plus d'effet. C'est ce qui faisait appeler le
   port 8090 alors que le serveur écoutait sur 8091.

## Licence

MIT, comme Plume. `whisper.cpp` est MIT (Georgi Gerganov et contributeurs),
les modèles Whisper sont sous licence MIT (OpenAI).
