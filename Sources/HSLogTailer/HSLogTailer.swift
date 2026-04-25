// Sources/HSLogTailer/HSLogTailer.swift
// Kernel-level file tailer using DispatchSource.
// Emits complete log lines via AsyncStream<String>.
// Handles Hearthstone's log rotation (delete + recreate on each game session).

import Foundation

// MARK: - HSLogTailer

/// Actor that tails a file at a given path and yields complete lines
/// through an AsyncStream.  All mutable state is actor-isolated.
///
/// Usage:
/// ```swift
/// let tailer = HSLogTailer()
/// for await line in tailer.lines(at: powerLogPath) {
///     parser.process(line: line)
/// }
/// ```
public actor HSLogTailer {

    // MARK: Private state

    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject? = nil
    private var offset: UInt64 = 0
    private var unparsedData = Data()
    private var continuation: AsyncStream<String>.Continuation? = nil
    private var isRunning: Bool = false
    private var watchedPath: String = ""
    private var activeLogPath: String = ""
    private var pollTimer: Task<Void, Never>? = nil

    private var currentLogPath: String {
        let filename = URL(fileURLWithPath: watchedPath).lastPathComponent
        let appLogsDir = "/Applications/Hearthstone/Logs"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: appLogsDir) {
            let folders = contents.filter { $0.hasPrefix("Hearthstone_") }.sorted()
            if let latest = folders.last {
                return "\(appLogsDir)/\(latest)/\(filename)"
            }
        }
        return watchedPath
    }

    // The queue all DispatchSource callbacks fire on.
    // Serial so we never have two concurrent reads.
    private let ioQueue = DispatchQueue(
        label: "hs-helper.logtailer.io",
        qos: .utility
    )

    // MARK: Public interface

    public init() {}

    /// Returns an AsyncStream that yields complete log lines as Hearthstone
    /// writes them.  The stream runs until `stop()` is called or the actor
    /// is deallocated.
    ///
    /// Only one stream can be active per tailer instance.  Calling this a
    /// second time cancels the previous stream.
    public func lines(at path: String) -> AsyncStream<String> {
        // Cancel any previous session cleanly.
        cancelSource()
        pollTimer?.cancel()
        pollTimer = nil

        watchedPath = path
        isRunning = true
        activeLogPath = ""

        return AsyncStream<String> { [weak self] cont in
            guard let self else {
                cont.finish()
                return
            }

            // Store the continuation so our DispatchSource handler can yield into it.
            Task {
                await self.setContinuation(cont)
                await self.startWatching()
                await self.startPolling()
            }

            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.stop() }
            }
        }
    }

    /// Gracefully stop tailing and finish the stream.
    public func stop() {
        isRunning = false
        pollTimer?.cancel()
        pollTimer = nil
        cancelSource()
        continuation?.finish()
        continuation = nil
    }

    // MARK: Internal helpers — all called on the actor

    private func setContinuation(_ cont: AsyncStream<String>.Continuation) {
        self.continuation = cont
    }

    /// Entry point: open the file (waiting if it doesn't exist yet), then
    /// install the DispatchSource.
    private func startWatching() {
        guard isRunning else { return }

        let path = currentLogPath
        print("HSLogTailer: startWatching at \(path)")

        // If the file doesn't exist, poll until it appears.
        guard FileManager.default.fileExists(atPath: path) else {
            print("HSLogTailer: File doesn't exist yet, scheduling retry...")
            scheduleRetry()
            return
        }

        openFile()
    }

    /// Open the file, seek to the current offset (0 on first open / after
    /// rotation), and install a DispatchSource that fires on every write.
    private func openFile() {
        let pathToOpen = currentLogPath
        print("HSLogTailer: openFile \(pathToOpen)")
        let fd = Darwin.open(pathToOpen, O_RDONLY | O_NONBLOCK)
        guard fd != -1 else {
            print("HSLogTailer: open failed for \(pathToOpen)")
            scheduleRetry()
            return
        }

        activeLogPath = pathToOpen
        fileDescriptor = fd

        // If offset is 0, attempt to find the start of the current match to avoid
        // flooding the main thread with old games from this session.
        if offset == 0 {
            findInitialOffset()
        }

        // On initial open read everything already in the file so we don't miss
        // lines that were written before we started (e.g. app launched mid-game).
        readNewBytes()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: ioQueue
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            // Copy the event mask into a plain UInt (Sendable) before the
            // async hop so Swift 6 strict concurrency is satisfied.
            let rawMask: UInt = src.data.rawValue

            Task {
                await self.handleSourceEvent(rawMask: rawMask)
            }
        }

        src.setCancelHandler { [fd] in
            Darwin.close(fd)
        }

        src.resume()
        source = src
    }

    /// Called by the DispatchSource event handler.
    /// Receives the raw mask value (a plain UInt) so it can cross the
    /// actor boundary without a Sendable violation.
    private func handleSourceEvent(rawMask: UInt) {
        let mask = DispatchSource.FileSystemEvent(rawValue: rawMask)
        guard isRunning else { return }

        // Rotation: the file was deleted or renamed (Hearthstone creates a
        // fresh Power.log at the start of every game session).
        if mask.contains(.delete) || mask.contains(.rename) {
            print("HSLogTailer: Source event - rotate (delete/rename)")
            cancelSource()
            offset = 0
            unparsedData.removeAll(keepingCapacity: false)
            // Brief delay — give HS time to create the new file.
            scheduleRetry(after: .seconds(1))
            return
        }

        if mask.contains(.write) {
            readNewBytes()
        }
    }

    /// Read all bytes written since `offset`, split into lines, yield each one.
    private func readNewBytes() {
        guard fileDescriptor != -1 else { return }

        // Seek to where we left off.
        let seekResult = lseek(fileDescriptor, off_t(offset), SEEK_SET)
        guard seekResult != -1 else { return }

        // Read in chunks.
        let chunkSize = 65_536
        var newData = Data()

        while true {
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            let bytesRead = Darwin.read(fileDescriptor, &buffer, chunkSize)
            if bytesRead <= 0 { break }
            newData.append(contentsOf: buffer[..<bytesRead])
        }

        guard !newData.isEmpty else { return }

        print("HSLogTailer: Read \(newData.count) new bytes")
        offset += UInt64(newData.count)

        unparsedData.append(newData)

        // Extract lines ending with \n
        while let newlineIndex = unparsedData.firstIndex(of: 0x0A) {  // 0x0A is \n
            let lineData = unparsedData[..<newlineIndex]
            unparsedData.removeSubrange(...newlineIndex)

            let line = String(decoding: lineData, as: UTF8.self)
            if true {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    continuation?.yield(trimmed)
                }
            }
        }
    }

    private func findInitialOffset() {
        guard fileDescriptor != -1 else { return }

        let fileSize = lseek(fileDescriptor, 0, SEEK_END)
        guard fileSize > 0 else {
            offset = 0
            return
        }

        if activeLogPath.contains("Power.log") {
            let chunkSize: off_t = 256 * 1024
            var currentPos = fileSize
            var overlap = Data()
            let createGameData = Data("CREATE_GAME".utf8)
            let newline = Data("\n".utf8).first!

            while currentPos > 0 {
                let readSize = min(chunkSize, currentPos)
                currentPos -= readSize

                lseek(fileDescriptor, currentPos, SEEK_SET)
                var buffer = [UInt8](repeating: 0, count: Int(readSize))
                let bytesRead = Darwin.read(fileDescriptor, &buffer, Int(readSize))

                if bytesRead <= 0 { break }

                var data = Data(buffer[..<bytesRead])
                data.append(overlap)

                if let range = data.range(of: createGameData, options: .backwards) {
                    var startOfLine = range.lowerBound
                    while startOfLine > data.startIndex {
                        if data[startOfLine - 1] == newline {
                            break
                        }
                        startOfLine -= 1
                    }
                    let byteDistance = data.distance(from: data.startIndex, to: startOfLine)
                    offset = UInt64(currentPos) + UInt64(byteDistance)
                    return
                }

                if data.count > 100 {
                    overlap = data.suffix(100)
                } else {
                    overlap = data
                }
            }
        }

        offset = 0
    }

    private func startPolling() {
        pollTimer?.cancel()
        pollTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.checkLogPathChanged()
            }
        }
    }

    private func checkLogPathChanged() {
        guard isRunning else { return }
        let newPath = currentLogPath
        if newPath != activeLogPath {
            print("HSLogTailer: Active log path changed from \(activeLogPath) to \(newPath)")
            cancelSource()
            offset = 0
            unparsedData.removeAll(keepingCapacity: false)
            startWatching()
        }
    }

    /// Cancel and release the current DispatchSource without closing the fd
    /// (the cancel handler does that).
    private func cancelSource() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    /// Retry opening the file after a delay (used while HS hasn't created
    /// the log yet, or immediately after rotation).
    private func scheduleRetry(after duration: Duration = .seconds(2)) {
        guard isRunning else { return }
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            await self?.startWatching()
        }
    }
}
