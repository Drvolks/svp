import CoreMedia
import Foundation
import PlayerCore

public final class AudioSynchronizer: @unchecked Sendable {
    private let hardSyncThresholdSeconds: Double
    private let softClampSeconds: Double

    public func correctedVideoPTS(videoPTS: CMTime, audioClock: CMTime) -> CMTime {
        guard videoPTS.isValid, audioClock.isValid else { return audioClock }
        let drift = videoPTS - audioClock
        if abs(drift.seconds) >= hardSyncThresholdSeconds {
            return audioClock
        }
        if abs(drift.seconds) <= softClampSeconds {
            return videoPTS
        }
        let correction = CMTime(seconds: drift.seconds * 0.5, preferredTimescale: 90_000)
        return videoPTS - correction
    }

    public init(hardSyncThresholdSeconds: Double = 0.200, softClampSeconds: Double = 0.020) {
        self.hardSyncThresholdSeconds = hardSyncThresholdSeconds
        self.softClampSeconds = softClampSeconds
    }
}

extension AudioSynchronizer {
    public static let `default` = AudioSynchronizer()
}
