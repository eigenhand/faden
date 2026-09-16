import Foundation

/// Decides when a spoken sentence has ended.
///
/// Two signals rather than one: the microphone level, and whether the recogniser is
/// still producing new words. Level alone misfires in a noisy room and cuts people
/// off mid-thought during a pause; the transcript alone lags behind by a second or
/// more. Together they hold: silence counts only while the room is quiet *and*
/// nothing new has been transcribed.
@MainActor
@Observable
final class SilenceDetector {

    /// How long the quiet has to last before the turn is considered over.
    var requiredSilence: TimeInterval = 2.0
    /// Level below which the input counts as quiet, in dBFS.
    private(set) var threshold: Float = -38

    private(set) var heardSpeech = false
    private(set) var silenceElapsed: TimeInterval = 0
    /// 0…1 for the UI.
    private(set) var level: Float = 0

    private var lastLoud: Date?
    private var lastTranscriptChange: Date?
    private var lastTranscript = ""
    private var started = Date()
    /// Rolling estimate of the room, used to lift the threshold in noisy places.
    private var noiseFloor: Float = -60
    private var calibrationSamples = 0

    var progress: Double {
        guard heardSpeech, requiredSilence > 0 else { return 0 }
        return min(1, silenceElapsed / requiredSilence)
    }

    func reset() {
        heardSpeech = false
        silenceElapsed = 0
        level = 0
        lastLoud = nil
        lastTranscriptChange = nil
        lastTranscript = ""
        started = Date()
        noiseFloor = -60
        calibrationSamples = 0
        threshold = -38
    }

    /// Feeds one measurement. Returns true when the turn should end.
    @discardableResult
    func feed(db: Float, transcript: String, now: Date = Date()) -> Bool {
        level = max(0, min(1, (db + 60) / 60))

        // The first half second is treated as room tone, so a loud kitchen does not
        // read as continuous speech.
        if calibrationSamples < 25, now.timeIntervalSince(started) < 0.6 {
            noiseFloor = calibrationSamples == 0 ? db : (noiseFloor * 0.8 + db * 0.2)
            calibrationSamples += 1
            threshold = max(-45, min(-25, noiseFloor + 12))
            return false
        }

        if transcript != lastTranscript {
            lastTranscript = transcript
            lastTranscriptChange = now
            if !transcript.isEmpty { heardSpeech = true }
        }

        let loud = db > threshold
        if loud {
            lastLoud = now
            heardSpeech = true
        }

        // Nothing said yet? Then keep waiting — a slow start is not a finished turn.
        guard heardSpeech else { silenceElapsed = 0; return false }

        let quietSince = lastLoud ?? started
        let stableSince = lastTranscriptChange ?? started
        // The turn is over only once *both* have been quiet long enough.
        silenceElapsed = min(now.timeIntervalSince(quietSince), now.timeIntervalSince(stableSince))
        return silenceElapsed >= requiredSilence
    }
}
