import Foundation

func getLatestLogFolder() -> String? {
    let appLogsDir = "/Applications/Hearthstone/Logs"
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: appLogsDir) else { return nil }
    let folders = contents.filter { $0.hasPrefix("Hearthstone_") }.sorted()
    return folders.last.map { "\(appLogsDir)/\($0)" }
}

guard let folder = getLatestLogFolder() else {
    print("No log folder")
    exit(1)
}

print("Simulating from: \(folder)")

let decksFile = "\(folder)/Decks.log"
let powerFile = "\(folder)/Power.log"

var deckLines = (try? String(contentsOfFile: decksFile, encoding: .utf8))?.components(separatedBy: "\n") ?? []
var powerLines = (try? String(contentsOfFile: powerFile, encoding: .utf8))?.components(separatedBy: "\n") ?? []

print("Decks lines: \(deckLines.count)")
print("Power lines: \(powerLines.count)")

// Just want to test if our HSLogParser extracts the deck correctly.
