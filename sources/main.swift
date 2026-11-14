import Foundation

// plume — la dictee de Plume sous Linux.
//
// Le geste est celui du Mac : on appuie sur une touche, on parle, le texte
// apparait la ou est le curseur.
//
// Ce binaire ne reecrit PAS Plume : il reutilise ses morceaux — SpeechGate
// (barriere anti-silence, decoupage en morceaux de 8 s qui coupent entre deux
// mots, WAV 16 kHz), SpeechEngine (le client du moteur HTTP), Polisher (le
// lissage), Leet (le 1337), Vocabulary — et ne remplace que ce qui n'existe
// pas hors d'Apple :
//
//   micro    : parecord (PipeWire / PulseAudio), 16 kHz mono s16le
//   moteur   : whisper-server compile sous Linux, MEME API que sur macOS
//   collage  : xdotool type
//   touche   : un raccourci du bureau qui lance `plume trigger`
//
// Usage :
//   plume listen      dicter au clavier (Entree pour arreter)
//   plume trigger     une dictee (depuis un raccourci du bureau)
//   plume text x.wav  transcrire un fichier WAV
//   plume check       verifier micro, moteur et outils

// MARK: - Outils systeme

enum Shell {
    static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Colle le texte la ou est le curseur (X11).
    ///
    /// `--clearmodifiers` est indispensable : la touche de dictée est encore
    /// enfoncée quand on colle, et un modificateur actif transformerait le
    /// texte (Maj + une lettre donne une majuscule).
    @discardableResult
    static func paste(_ text: String) -> Bool {
        guard !text.isEmpty, let tool = which("xdotool") else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["type", "--clearmodifiers", "--delay", "0", text]
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: - Pont synchrone
//
// Tout est synchrone ici : une dictee est une suite d'etapes, et il n'y a pas
// d'interface a rafraichir pendant l'attente. C'est plus simple que le pont
// avec une boucle GTK, et ca ne change rien pour l'utilisateur.

// MARK: - Attente d'une tache asynchrone
//
// Piege paye ici : `DispatchSemaphore.wait()` sur le fil principal fige aussi
// le pool de threads que Swift concurrency utilise en mode console (sans
// RunLoop qui tourne). La tache n'a alors plus de fil ou s'executer et on
// attend indefiniment. On fait donc respirer le RunLoop entre deux essais.

func runAndWait<T>(_ work: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: T?
    Task.detached(priority: .userInitiated) {
        result = await work()
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.02) == .timedOut {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return result!
}

func runAndWait<T>(_ work: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task.detached(priority: .userInitiated) {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.02) == .timedOut {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return try result!.get()
}

// MARK: - Programme

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
// Le modele actif : celui que l'utilisateur a choisi (`plume models use`),
// sinon Whisper Turbo compact. Le catalogue est celui de Plume, inchange.
let modelID = ModelsCLI.selectedID

// Sous Linux, 8090 est souvent deja pris (ici par crowdsec, ailleurs par
// un autre service) : PLUME_PORT deplace le moteur sans toucher au code.
// Ordre : PLUME_PORT (explicite), puis le port enregistre a l'installation,
// puis celui du catalogue. Sans cela, `plume check` annoncait 8090 pendant
// que le service systemd ecoutait sur 8091.
if let raw = ProcessInfo.processInfo.environment["PLUME_PORT"], let n = Int(raw) {
    ModelCatalog.portOverride = n
} else if let saved = LocalConfig.current?.enginePort {
    ModelCatalog.portOverride = saved
}

/// Le verdict de la barriere anti-silence, tel que Plume le calcule.
func describe(_ verdict: SpeechGate.Verdict) -> String {
    guard let range = verdict.range else { return "silence (\(verdict.reason))" }
    let secs = Double(range.count) / AudioRecorder.sampleRate
    return String(format: "parole, %.1f s (%@)", secs, verdict.reason)
}

switch command {

case "models":
    ModelsCLI.run(Array(args.dropFirst()))

case "check":
    let m = ModelCatalog.model(modelID)
    print("=== plume check ===")
    print("modele       : \(m?.id ?? "?")  — port \(m?.port ?? 0)")
    print("whisper      : \(Setup.whisperBinary ?? "introuvable (voir ~/.config/plume/local.json)")")
    print("parecord     : \(Shell.which("parecord") ?? "MANQUANT — apt install pulseaudio-utils")")
    print("xdotool      : \(Shell.which("xdotool") ?? "MANQUANT — apt install xdotool")")
    print("memoire      : \(String(format: "%.1f", Setup.availableMemoryGB)) Go disponibles")
    print("processeur   : \(Setup.chipName)")
    print("langue       : \(Setup.systemLanguage)")
    print("config       : \(LocalConfig.current == nil ? "aucune (~/.config/plume/local.json)" : "chargee")")

case "text":
    guard let path = args.dropFirst().first else {
        print("usage : plume text <fichier.wav>")
        exit(1)
    }
    guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("fichier illisible : \(path)")
        exit(1)
    }
    // En-tete RIFF (44 octets) -> PCM16 -> flottants.
    let pcm = raw.count > 44 ? raw.dropFirst(44) : raw
    var samples: [Float] = []
    samples.reserveCapacity(pcm.count / 2)
    pcm.withUnsafeBytes { buf in
        for v in buf.bindMemory(to: Int16.self) { samples.append(Float(v) / 32768) }
    }
    let verdict = SpeechGate.analyse(samples)
    print("audio        : \(String(format: "%.1f", Double(samples.count) / 16000)) s — \(describe(verdict))")
    let ranges = SpeechGate.chunks(of: samples, range: 0..<samples.count)
    print("morceaux     : \(ranges.count)")
    let model = ModelCatalog.model(modelID) ?? ModelCatalog.all[0]
    // S'attacher au moteur s'il tourne, le lancer sinon (regle de SpeechEngine).
    // ensureRunning rend le port REEL (8091 si 8090 est pris par autre chose) :
    // on le pose dans le catalogue pour que SpeechEngine construise son URL
    // sur ce port-la, pas sur celui du catalogue macOS.
    guard let enginePort = EngineLauncher.ensureRunning(model) else {
        FileHandle.standardError.write(Data(
            "moteur indisponible : verifie ~/.config/plume/local.json\n".utf8))
        exit(4)
    }
    ModelCatalog.portOverride = enginePort
    // ⚠️ Re-lire le modele APRES avoir pose le port : la valeur lue avant
    // garde le port du catalogue (8090), et SpeechEngine appellerait le mauvais.
    let engineModel = ModelCatalog.model(modelID) ?? model
    let text = runAndWait { () -> String in
        var full = ""
        for r in ranges {
            if let t = try? await SpeechEngine.engine(for: engineModel)
                .transcribe(wav: SpeechGate.wav(samples[r]), language: "fr"),
               !t.isEmpty {
                full += (full.isEmpty ? "" : " ") + t
            }
        }
        return full
    }
    print("transcrit    : \(text.isEmpty ? "(rien)" : text)")

case "listen", "trigger":
    // 0. La pastille, si elle est installee et qu'il y a un affichage.
    //    Elle n'est pas indispensable : sans elle, la dictee marche quand meme.
    let pill = PillClient()
    pill.start()

    // 1. Le micro.
    let rec = AudioRecorder()
    // Le niveau du micro alimente les barres de la pastille, ~20 fois/s,
    // exactement comme le LevelMeter de l'app macOS.
    rec.onLevel = { level in pill.level(level) }
    do {
        try rec.start()
    } catch {
        pill.hide()
        pill.finish(after: 0)
        print("micro indisponible : \(error.localizedDescription)")
        exit(2)
    }
    pill.recording()
    FileHandle.standardError.write(Data("Plume écoute… (Entrée pour arrêter)\n".utf8))

    if command == "listen" {
        // ⚠️ Si stdin n'est pas un terminal (pipe, raccourci du bureau, script),
        // `read` rend 0 tout de suite et la dictee s'arrete en quelques
        // millisecondes : « silence (trop court) ». On ne lit donc que sur un
        // vrai terminal ; sinon on attend la duree demandee, comme `trigger`.
        if isatty(0) != 0 {
            var b: UInt8 = 0
            while read(0, &b, 1) > 0 {
                if b == 10 || b == 13 { break }
            }
        } else {
            let secs = Double(ProcessInfo.processInfo.environment["PLUME_SECONDS"] ?? "") ?? 12
            Thread.sleep(forTimeInterval: secs)
        }
    } else {
        // `trigger` : sans terminal (raccourci du bureau), on enregistre un
        // temps fixe reglable. Simple, previsible, sans fichier drapeau.
        let secs = Double(ProcessInfo.processInfo.environment["PLUME_SECONDS"] ?? "") ?? 15
        Thread.sleep(forTimeInterval: secs)
    }

    // 2. L'audio, passe par la barriere anti-silence de Plume.
    let samples = rec.stop()
    pill.processing()
    let verdict = SpeechGate.analyse(samples)
    FileHandle.standardError.write(Data("fin : \(describe(verdict))\n".utf8))
    guard let range = verdict.range else {
        pill.hide()
        pill.finish(after: 0)
        print("")
        exit(0)
    }

    // 3. La transcription, decoupee comme le fait l'app.
    let ranges = SpeechGate.chunks(of: samples, range: range)
    let model = ModelCatalog.model(modelID) ?? ModelCatalog.all[0]
    // Le moteur du modele choisi : `plume models use` change le port, encore
    // faut-il que quelqu'un lance le serveur dessus.
    guard let enginePort = EngineLauncher.ensureRunning(model) else {
        pill.hide()
        pill.finish(after: 0)
        FileHandle.standardError.write(Data(
            "moteur indisponible : verifie ~/.config/plume/local.json\n".utf8))
        exit(4)
    }
    ModelCatalog.portOverride = enginePort
    // Meme piege que dans `text` : re-lire apres avoir pose le port.
    let engineModel = ModelCatalog.model(modelID) ?? model
    do {
        let full = try runAndWait { () -> String in
            var acc = ""
            for r in ranges {
                let t = try await SpeechEngine.engine(for: engineModel)
                    .transcribe(wav: SpeechGate.wav(samples[r]), language: "fr")
                if !t.isEmpty { acc += (acc.isEmpty ? "" : " ") + t }
            }
            return acc
        }
        guard !full.isEmpty else {
            pill.hide()
            pill.finish(after: 0)
            print("")
            exit(0)
        }

        // 4. Le lissage (facultatif : sans cle API il rend nil, on colle quand meme).
        let clean = runAndWait { await Polisher.polish(full, language: .fr) } ?? full

        // 5. Le collage au curseur.
        let pasted = Shell.paste(clean)
        if !pasted {
            FileHandle.standardError.write(Data("xdotool absent : texte affiche seulement\n".utf8))
        }
        // La pastille montre le ✓ vert un instant, comme sur macOS.
        pill.pasted()
        pill.finish(after: 0.9)
        print(clean)
        _ = runAndWait { await SpeechEngine.engine(for: model)
            .scheduleIdleRelease(after: SpeechEngine.defaultIdleSeconds) }
    } catch {
        pill.hide()
        pill.finish(after: 0)
        FileHandle.standardError.write(Data("echec du moteur : \(error.localizedDescription)\n".utf8))
        exit(3)
    }

default:
    print("""
    plume — la dictee de Plume sous Linux

      plume listen      dicter au clavier (Entree pour commencer et arreter)
      plume trigger     dicter depuis un raccourci du bureau (duree : PLUME_SECONDS, 15 s par defaut)
      plume text x.wav  transcrire un fichier WAV
      plume models      choisir un modele (et le telecharger)
      plume check       verifier l'installation

    Le moteur whisper-server doit tourner. Voir install.sh.
    """)
}
