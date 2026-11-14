import Foundation

/// Le micro, sous Linux — seulement pendant une dictée : `start()` à l'appui,
/// `stop()` à la fin. Rien n'écoute entre deux dictées.
///
/// C'est la même idée que la version macOS (`AVAudioEngine`), avec `parecord`
/// à la place : PipeWire et PulseAudio fournissent tous deux `parecord`, qui
/// écrit du PCM brut sur sa sortie standard. On lui demande directement du
/// **16 kHz mono signé 16 bits** — ce que mange Whisper — donc **aucune
/// conversion à faire**, contrairement au Mac où il faut rééchantillonner.
///
/// Pas de traitement de la voix (AEC/AGC), comme sur macOS : un AGC peut
/// baisser le gain matériel du micro et le laisser bas après coup.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Niveau du son (0…1), appelé ~20 fois par seconde.
    var onLevel: (@Sendable (Float) -> Void)?

    private var process: Process?
    private var pipe: Pipe?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var reader: Task<Void, Never>?

    enum RecorderError: LocalizedError {
        case noInput
        case noRecorder
        var errorDescription: String? {
            switch self {
            case .noInput: return "Aucun micro disponible"
            case .noRecorder: return "parecord introuvable (paquet pulseaudio-utils ou pipewire-bin)"
            }
        }
    }

    /// Le binaire d'enregistrement présent sur la machine.
    static var recorderBinary: String? {
        for path in ["/usr/bin/parecord", "/usr/local/bin/parecord", "/bin/parecord"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/parecord"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        guard let binary = Self.recorderBinary else { throw RecorderError.noRecorder }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        // --raw : pas d'en-tête WAV, on veut les échantillons bruts.
        p.arguments = [
            "--raw",
            "--format=s16le",
            "--rate=\(Int(Self.sampleRate))",
            "--channels=1",
        ]
        // Le micro choisi dans les réglages, sinon celui du système.
        if let source = UserDefaults.standard.string(forKey: "microphoneUID"), !source.isEmpty {
            p.arguments?.append("--device=\(source)")
        }

        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        pipe = out

        let handle = out.fileHandleForReading
        reader = Task.detached { [weak self] in
            var carry = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                carry.append(chunk)
                // PCM16 : on traite des paires d'octets, jamais un octet seul.
                let usable = carry.count - (carry.count % 2)
                guard usable > 0 else { continue }
                let block = carry.prefix(usable)
                carry = carry.subdata(in: usable..<carry.count)
                self?.append(block)
            }
        }

        Log.info("micro ouvert (\(Int(Self.sampleRate)) Hz, mono, parecord)")
    }

    private func append(_ data: Data) {
        var floats: [Float] = []
        floats.reserveCapacity(data.count / 2)
        var peak: Float = 0
        data.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for v in ints {
                // Int16 → −1…1, l'échelle que SpeechGate attend.
                let f = Float(v) / 32768
                floats.append(f)
                let a = abs(f)
                if a > peak { peak = a }
            }
        }
        lock.lock(); samples.append(contentsOf: floats); lock.unlock()
        onLevel?(min(1, peak * 3))
    }

    /// Arrête le micro et rend tout l'enregistrement (16 kHz mono).
    func stop() -> [Float] {
        if let p = process {
            // SIGTERM laisse parecord vider ce qu'il a déjà lu.
            p.terminate()
            p.waitUntilExit()
        }
        reader?.cancel()
        reader = nil
        process = nil
        pipe = nil
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }
}
