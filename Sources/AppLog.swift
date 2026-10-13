// AppLog.swift
// Tiny flight recorder: every line is appended to Documents/ScreenExt.log right away. Because the
// Info.plist enables file sharing, the file shows up in the Files app under
// "On My iPad/iPhone > Screen Extension", so you can read what happened right before a freeze or
// crash without a Mac. (Also: Settings > Privacy & Security > Analytics & Improvements > Analytics
// Data lists crash reports, if "Share iPad/iPhone Analytics" is on.)

import Foundation

enum AppLog {
    private static let queue = DispatchQueue(label: "applog", qos: .utility)

    private static let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ScreenExt.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static var handle: FileHandle? = {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 1_000_000 {
            try? fm.removeItem(at: url)                       // keep it small: start over past 1 MB
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    static func log(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) \(message)\n"
            if let data = line.data(using: .utf8) { try? handle?.write(contentsOf: data) }
        }
    }
}
