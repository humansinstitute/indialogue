import Foundation
import Speech
import AVFoundation

struct LocalTranscript { let text: String; let locale: String }

/// Older systems explicitly report unavailable. No cloud recognition path exists.
enum LocalSpeech {
    static func status() async -> String {
        guard #available(iOS 26, *), let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current),
              SpeechTranscriber.isAvailable else { return "Local transcription unavailable for this OS, device or language. Recording works independently." }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let installed = await AssetInventory.status(forModules: [module]) == .installed
        return "On-device transcription · \(locale.identifier). \(installed ? "Model installed." : "Model may need an explicit download.")"
    }
    static func transcribe(_ urls: [URL], download: Bool) async throws -> LocalTranscript {
        guard #available(iOS 26, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { throw RecorderError.unavailable }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let installed = await AssetInventory.status(forModules: [module]) == .installed
        guard installed || download else { throw RecorderError.modelRequired }
        if !installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            guard download else { throw RecorderError.modelRequired }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [module])
        let results = Task { () throws -> String in
            var parts: [String] = []
            for try await result in module.results { parts.append(String(result.text.characters)) }
            return parts.joined(separator: " ")
        }
        return try await withTaskCancellationHandler {
            do {
                var end: CMTime?
                for url in urls {
                    try Task.checkCancellation()
                    end = try await analyzer.analyzeSequence(from: AVAudioFile(forReading: url))
                }
                if let end { try await analyzer.finalizeAndFinish(through: end) }
                else { await analyzer.cancelAndFinishNow() }
                return LocalTranscript(text: try await results.value, locale: locale.identifier)
            } catch {
                await analyzer.cancelAndFinishNow()
                results.cancel()
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
