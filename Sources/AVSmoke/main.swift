import Dispatch
import CoreMedia
import Foundation
import Input
import PlayerCore
import SVP

final class SmokeVideoOutput: @unchecked Sendable, VideoOutput {
    private let lock = NSLock()
    private var frameCount = 0
    private var latestPTS: Double?

    func render(frame: DecodedVideoFrame) {
        let count = lock.withLock { () -> Int in
            frameCount += 1
            latestPTS = frame.pts.seconds
            return frameCount
        }
        if count == 1 || count % 120 == 0 {
            let pts = String(format: "%.3f", frame.pts.seconds)
            print("[AVSmoke] video_frame count=\(count) pts=\(pts)")
        }
    }

    func snapshot() -> (count: Int, latestPTS: Double?) {
        lock.withLock { (frameCount, latestPTS) }
    }
}

struct AVSmokeRunner {
    static func run() async throws {
        let args = CommandLine.arguments
        let videoURL: URL
        let audioURL: URL

        if args.count >= 3 {
            guard let parsedVideoURL = parseURLArgument(args[1]),
                  let parsedAudioURL = parseURLArgument(args[2]) else {
                fputs("invalid URL or path\n", stderr)
                Foundation.exit(2)
            }
            videoURL = parsedVideoURL
            audioURL = parsedAudioURL
        } else {
            guard let fixtureURLs = defaultFixtureURLs() else {
                fputs("missing AVSmoke fixtures; pass <videoURLOrPath> <audioURLOrPath> as arguments\n", stderr)
                Foundation.exit(2)
            }
            videoURL = fixtureURLs.video
            audioURL = fixtureURLs.audio
        }

        let durationSeconds: Double
        if args.count >= 4, let parsed = Double(args[3]), parsed > 0 {
            durationSeconds = parsed
        } else {
            durationSeconds = 20
        }

        let player = Player(
            videoSource: makeInputSource(url: videoURL),
            audioSource: makeInputSource(url: audioURL),
            preferHardwareDecode: true
        )
        let videoOutput = SmokeVideoOutput()
        await player.attachVideoOutput(videoOutput)

        let descriptor = SplitAVInputSource(
            videoSource: makeInputSource(url: videoURL),
            audioSource: makeInputSource(url: audioURL)
        ).descriptor

        let eventsTask = Task {
            var lastLoggedBucket = Int.min
            let events = await player.playbackEvents()
            for await event in events {
                switch event {
                case .stateChanged(let state):
                    print("[AVSmoke] state=\(state)")
                case .progress(let position, let duration):
                    let bucket = Int(position.seconds.rounded(.down) / 5)
                    if bucket != lastLoggedBucket {
                        lastLoggedBucket = bucket
                        let pos = String(format: "%.3f", position.seconds)
                        let dur = duration.map { String(format: "%.3f", $0.seconds) } ?? "nil"
                        print("[AVSmoke] progress position=\(pos) duration=\(dur)")
                    }
                case .stalled:
                    print("[AVSmoke] stalled")
                case .recovered:
                    print("[AVSmoke] recovered")
                case .ended:
                    print("[AVSmoke] ended")
                case .error(let message):
                    print("[AVSmoke] error=\(message)")
                }
            }
        }

        try await player.load(PlayableSource(descriptor: descriptor))
        await player.play()
        print("[AVSmoke] started seconds=\(durationSeconds)")

        let summaryTask = Task {
            let start = ProcessInfo.processInfo.systemUptime
            var nextSummary: Double = 5
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                guard elapsed >= nextSummary else { continue }
                let snapshot = videoOutput.snapshot()
                let position = await player.currentPosition()
                let pos = String(format: "%.3f", position.seconds)
                let latestVideo = snapshot.latestPTS.map { String(format: "%.3f", $0) } ?? "nil"
                print("[AVSmoke] summary elapsed=\(String(format: "%.1f", elapsed)) position=\(pos) videoFrames=\(snapshot.count) latestVideoPTS=\(latestVideo)")
                nextSummary += 5
            }
        }

        try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))

        let metrics = await player.playbackMetrics()
        let position = await player.currentPosition()
        let duration = await player.currentDuration()
        let pos = String(format: "%.3f", position.seconds)
        let dur = duration.map { String(format: "%.3f", $0.seconds) } ?? "nil"
        print("[AVSmoke] final position=\(pos) duration=\(dur)")
        let startupMs = metrics.startupTimeMs.map { String(format: "%.2f", $0) } ?? "nil"
        print("[AVSmoke] metrics startupMs=\(startupMs) stalls=\(metrics.rebufferCount) drops=\(metrics.decodeFailureCount)")

        await player.pause()
        summaryTask.cancel()
        eventsTask.cancel()
    }

    static func parseURLArgument(_ value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        let expanded = NSString(string: value).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func makeInputSource(url: URL) -> any InputSource {
        if url.isFileURL {
            return FileInputSource(url: url)
        }
        return HTTPInputSource(url: url)
    }

    static func defaultFixtureURLs() -> (video: URL, audio: URL)? {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        let candidateDirectories: [URL] = [
            cwd.appendingPathComponent("Sources/AVSmoke", isDirectory: true),
            cwd.appendingPathComponent("AVSmoke", isDirectory: true),
            cwd
        ]

        for directory in candidateDirectories {
            let video = directory.appendingPathComponent("1-h264.mp4")
            let audio = directory.appendingPathComponent("1-h264.aac")
            if fm.fileExists(atPath: video.path), fm.fileExists(atPath: audio.path) {
                return (video, audio)
            }
        }
        return nil
    }
}

let smokeSemaphore = DispatchSemaphore(value: 0)
var smokeExitCode: Int32 = 0

Task {
    do {
        try await AVSmokeRunner.run()
    } catch {
        fputs("AVSmoke failed: \(error)\n", stderr)
        smokeExitCode = 1
    }
    smokeSemaphore.signal()
}

smokeSemaphore.wait()
Foundation.exit(smokeExitCode)

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
