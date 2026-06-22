//
//  AptvMergeApp.swift
//  AptvMerge
//
//  Created by LPP on 2026/6/18.
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppProcessCleaner.cleanStaleProcesses()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppProcessCleaner.cleanStaleProcesses()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private enum AppProcessCleaner {
    static func cleanStaleProcesses() {
        [
            "AptvMerge/Runtime",
            "AptvMerge/Calibration",
            "AptvMerge/SinglePreview"
        ].forEach { pattern in
            run("/usr/bin/pkill", arguments: ["-f", pattern])
        }

        [8080, 8081, 8082].forEach { port in
            for pid in pidsListening(on: port) {
                let command = processCommand(pid: pid)
                if command.contains("http.server \(port)") || command.contains("AptvMerge/") {
                    run("/bin/kill", arguments: ["-TERM", pid])
                }
            }
        }
    }

    private static func pidsListening(on port: Int) -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-ti", "tcp:\(port)"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
    }

    private static func processCommand(pid: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", pid, "-o", "command="]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func run(_ executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

@main
struct AptvMergeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
