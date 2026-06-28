import Foundation

/// Serializes all Notion writes for one page through a single in-flight queue so
/// live transcript appends and the end-of-meeting summary never collide and we
/// stay under Notion's ~3 req/s limit. Batches ≤100 blocks per request, spaces
/// requests ~350ms apart, and on a 429 pauses for the Retry-After interval.
///
/// Ordering = arrival order (the queue is FIFO and single-flight), which keeps
/// the transcript in sequence. On a transport/5xx error the batch is retried;
/// on a 429 the whole queue pauses then resumes.
public actor AppendQueue {
    public enum Health: Sendable, Equatable {
        case idle              // caught up
        case syncing(pending: Int)
        case retrying(after: Double)
        case failed(String)
    }

    private let client: NotionClient
    private let pageID: String
    private let spacing: Duration
    private var buffer: [NotionBlock] = []
    private var draining = false
    private var failures = 0
    public private(set) var health: Health = .idle

    public init(client: NotionClient, pageID: String, spacingMilliseconds: Int = 350) {
        self.client = client
        self.pageID = pageID
        self.spacing = .milliseconds(spacingMilliseconds)
    }

    /// Add blocks to the queue and ensure the drain loop is running.
    public func enqueue(_ blocks: [NotionBlock]) {
        guard !blocks.isEmpty else { return }
        buffer.append(contentsOf: blocks)
        health = .syncing(pending: buffer.count)
        if !draining {
            draining = true
            Task { await self.drain() }
        }
    }

    /// Block until the queue has fully drained (used on stop, before declaring
    /// the session safely written).
    public func flush() async {
        while draining || !buffer.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func drain() async {
        defer { draining = false }
        while !buffer.isEmpty {
            let batch = Array(buffer.prefix(NotionClient.maxBlocksPerRequest))
            do {
                try await client.appendChildren(pageID: pageID, blocks: batch)
                buffer.removeFirst(batch.count)   // advance only on confirmed success
                failures = 0
                health = buffer.isEmpty ? .idle : .syncing(pending: buffer.count)
                try? await Task.sleep(for: spacing)
            } catch NotionError.rateLimited(let retryAfter) {
                health = .retrying(after: retryAfter)
                try? await Task.sleep(for: .seconds(retryAfter))
            } catch let error as NotionError {
                // Transport/5xx — retry with backoff; auth/share errors surface.
                switch error {
                case .transport, .http:
                    failures += 1
                    if failures >= 5 { health = .failed("\(error)"); return }
                    health = .retrying(after: Double(failures))
                    try? await Task.sleep(for: .seconds(Double(failures)))
                default:
                    health = .failed("\(error)")
                    return
                }
            } catch {
                health = .failed("\(error)")
                return
            }
        }
        health = .idle
    }
}
