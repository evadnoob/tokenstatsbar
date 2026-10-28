import CoreServices
import Foundation

/// Watches a directory tree with FSEvents and calls `onChange` on the main queue, debounced to one second.
/// A repeating timer calls it every 60 seconds as a fallback.
final class SessionWatcher {
    private let directory: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?
    private var timer: Timer?

    init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SessionWatcher>.fromOpaque(info).takeUnretainedValue().scheduleChange()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        if let created = FSEventStreamCreate(
            nil, callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) {
            stream = created
            FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
            FSEventStreamStart(created)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.onChange() }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        timer?.invalidate()
        timer = nil
        debounce?.cancel()
    }

    private func scheduleChange() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    deinit { stop() }
}
