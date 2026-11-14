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
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
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
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return try result!.get()
}

// MARK: - Programme

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let modelID = "whisper-turbo-q5"

// Sous Linux, 8090 est souvent deja pris (ici par crowdsec, ailleurs par
// un autre service) : PLUME_PORT deplace le moteur sans toucher au code.
if let raw = ProcessInfo.processInfo.environment["PLUME_PORT"], let n = Int(raw) {
    ModelCatalog.portOverride = n
}

/// Le verdict de la barriere anti-silence, tel que Plume le calcule.
func describe(_ verdict: SpeechGate.Verdict) -> String {
    guard let range = verdict.range else { return "silence (\(verdict.reason))" }
    let secs = Double(range.count) / AudioRecorder.sampleRate
    return String(format: "parole, %.1f s (%@)", secs, verdict.reason)
}

switch command {

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
    let text = runAndWait { () -> String in
        var full = ""
        for r in ranges {
            if let t = try? await SpeechEngine.engine(for: model)
                .transcribe(wav: SpeechGate.wav(samples[r]), language: "fr") {
                if !t.isEmpty { full += (full.isEmpty ? "" : " ") + t }
            }
        }
        return full
    }
    print("transcrit    : \(text.isEmpty ? "(rien)" : text)")

case "listen", "trigger":
    // 1. Le micro.
    let rec = AudioRecorder()
    do {
        try rec.start()
    } catch {
        print("micro indisponible : \(error.localizedDescription)")
        exit(2)
    }
    FileHandle.standardError.write(Data("Plume écoute… (Entrée pour arrêter)\n".utf8))

    if command == "listen" {
        var b: UInt8 = 0
        while read(0, &b, 1) > 0 {
            if b == 10 || b == 13 { break }
        }
    } else {
        // `trigger` : sans terminal (raccourci du bureau), on enregistre un
        // temps fixe reglable. Simple, previsible, sans fichier drapeau.
        let secs = Double(ProcessInfo.processInfo.environment["PLUME_SECONDS"] ?? "") ?? 15
        Thread.sleep(forTimeInterval: secs)
    }

    // 2. L'audio, passe par la barriere anti-silence de Plume.
    let samples = rec.stop()
    let verdict = SpeechGate.analyse(samples)
    FileHandle.standardError.write(Data("fin : \(describe(verdict))\n".utf8))
    guard let range = verdict.range else {
        print("")
        exit(0)
    }

    // 3. La transcription, decoupee comme le fait l'app.
    let ranges = SpeechGate.chunks(of: samples, range: range)
    let model = ModelCatalog.model(modelID) ?? ModelCatalog.all[0]
    do {
        let full = try runAndWait { () -> String in
            var acc = ""
            for r in ranges {
                let t = try await SpeechEngine.engine(for: model)
                    .transcribe(wav: SpeechGate.wav(samples[r]), language: "fr")
                if !t.isEmpty { acc += (acc.isEmpty ? "" : " ") + t }
            }
            return acc
        }
        guard !full.isEmpty else { print(""); exit(0) }

        // 4. Le lissage (facultatif : sans cle API il rend nil, on colle quand meme).
        let clean = runAndWait { await Polisher.polish(full, language: .fr) } ?? full

        // 5. Le collage au curseur.
        if Shell.paste(clean) {
            print(clean)
        } else {
            FileHandle.standardError.write(Data("xdotool absent : texte affiche seulement\n".utf8))
            print(clean)
        }
        _ = runAndWait { await SpeechEngine.engine(for: model)
            .scheduleIdleRelease(after: SpeechEngine.defaultIdleSeconds) }
    } catch {
        FileHandle.standardError.write(Data("echec du moteur : \(error.localizedDescription)\n".utf8))
        exit(3)
    }

default:
    print("""
    plume — la dictee de Plume sous Linux

      plume listen      dicter au clavier (Entree pour commencer et arreter)
      plume trigger     dicter depuis un raccourci du bureau (duree : PLUME_SECONDS, 15 s par defaut)
      plume text x.wav  transcrire un fichier WAV
      plume check       verifier l'installation

    Le moteur whisper-server doit tourner. Voir install.sh.
    """)
}
