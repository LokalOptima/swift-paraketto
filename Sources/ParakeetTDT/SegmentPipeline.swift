import CoreML
import Foundation

/// Encodes the segments of a file on one queue (Neural Engine) while the previous segment is decoded
/// on another (CPU), so an import no longer waits for the decoder between encoder passes. The session
/// applies the results in submission order, so the transcript is the same as encoding and decoding
/// each segment in turn.
final class SegmentPipeline {
    /// What the session needs to join a decoded segment to its neighbours.
    struct Segment {
        let range: Range<Int>
        let overlapped: Bool
        let previousBoundary: Int
        let previousOverlapped: Bool
    }

    struct Job {
        let segment: Segment
        /// Window starts tried in order until one decodes to tokens.
        let starts: [Int]
        let windowEnd: Int
        /// Audio from the earliest start to `windowEnd`.
        let audio: [Float]
        let audioStartFrame: Int
    }

    struct Decoded {
        let segment: Segment
        let tokens: [ParakeetTranscriber.Token]
        let windowStart: Int
    }

    private let transcriber: ParakeetTranscriber
    private let encodeQueue = DispatchQueue(label: "ParakeetTDT.encode")
    private let decodeQueue = DispatchQueue(label: "ParakeetTDT.decode")
    /// Two segments in flight let the next encoder pass overlap the current decode; more only add memory.
    private let slots = DispatchSemaphore(value: 2)
    private let work = DispatchGroup()
    private let lock = NSLock()
    private var results: [Decoded?] = []
    private var failure: Error?
    private var cancelled = false
    /// Written only on their own queues; read once `work` is done.
    private(set) var encodeSeconds = 0.0
    private(set) var decodeSeconds = 0.0

    init(transcriber: ParakeetTranscriber) {
        self.transcriber = transcriber
    }

    /// Queues a segment and returns its index; waits while two are still being worked on.
    func submit(_ job: Job) throws -> Int {
        if let failure = lock.withLock({ failure }) { throw failure }
        slots.wait()
        let index = lock.withLock { () -> Int in
            results.append(nil)
            return results.count - 1
        }
        work.enter()
        encodeQueue.async { [self] in
            let encoded = isStopped ? .success(nil) : autoreleasepool { Result { try encode(job, start: 0) } }
            decodeQueue.async { [self] in
                autoreleasepool { complete(job, index: index, firstEncoding: encoded) }
                slots.signal()
                work.leave()
            }
        }
        return index
    }

    /// Every submitted segment, in submission order.
    func finish() throws -> [Decoded] {
        work.wait()
        return try lock.withLock {
            if let failure { throw failure }
            return results.map { $0! }
        }
    }

    /// Skips queued work and waits for the segment in progress, so the shared models are free again.
    func cancel() {
        lock.withLock { cancelled = true }
        work.wait()
    }

    private var isStopped: Bool { lock.withLock { cancelled || failure != nil } }

    /// Encoder frames for `job.starts[start]`, or nil when that window is too short to decode.
    private func encode(_ job: Job, start: Int) throws -> EncoderFrames? {
        let from = (job.starts[start] - job.audioStartFrame) * ParakeetConstants.samplesPerFrame
        let to = min((job.windowEnd - job.audioStartFrame) * ParakeetConstants.samplesPerFrame, job.audio.count)
        guard to - from >= ParakeetConstants.minimumSamples else { return nil }
        let t0 = Date()
        let frames = try transcriber.encode(transcriber.preprocess(job.audio[from..<to]))
        encodeSeconds += Date().timeIntervalSince(t0)
        return frames
    }

    /// Decodes the first window that yields tokens, encoding later starts only when needed.
    private func complete(_ job: Job, index: Int, firstEncoding: Result<EncoderFrames?, Error>) {
        guard !isStopped else { return }
        do {
            var encoded = try firstEncoding.get()
            var tokens: [ParakeetTranscriber.Token] = []
            var windowStart = job.starts[0]
            for start in job.starts.indices {
                windowStart = job.starts[start]
                if start > 0 {
                    encoded = try encodeQueue.sync { try autoreleasepool { try encode(job, start: start) } }
                }
                if let encoded {
                    let t0 = Date()
                    tokens = try transcriber.decoder.decode(encoded).map {
                        ParakeetTranscriber.Token(id: $0.id, frame: windowStart + $0.frame)
                    }
                    decodeSeconds += Date().timeIntervalSince(t0)
                } else {
                    tokens = []
                }
                if !tokens.isEmpty { break }
            }
            let decoded = Decoded(segment: job.segment, tokens: tokens, windowStart: windowStart)
            lock.withLock { results[index] = decoded }
        } catch {
            lock.withLock { if failure == nil { failure = error } }
        }
    }
}
