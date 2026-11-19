import Foundation
import SwiftUI

@main struct Entry {
    @MainActor static func main() {
        #if os(macOS) && DEBUG
        if ProcessInfo.processInfo.arguments.contains("--network-qa") {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cliprelay-network-" + UUID().uuidString)
            Task {
                var status: Int32 = 0
                do { try await QA.testForwarding(in: scratch); print("PASS LAN pairing, relay and directory") }
                catch { print("FAIL LAN check · \(error)"); status = 1 }
                try? FileManager.default.removeItem(at: scratch)
                exit(status)
            }
            RunLoop.main.run()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--view-qa") {
            do { try MacViewCheck.run(); exit(0) }
            catch { print("FAIL hidden Mac layout · \(error)"); exit(1) }
        }
        if QA.active {
            Task { await QA.run(); exit(0) }
            RunLoop.main.run()
            return
        }
        #endif
        ClipRelayApp.main()
    }
}
