import Foundation

@main struct KeyboardSetupQA {
    static func main() {
        let first = KeyboardSetupCheck.challenge()
        let second = KeyboardSetupCheck.challenge()
        precondition(first != second)
        let limited = KeyboardSetupCheck.response(to: first, fullAccess: false)
        let full = KeyboardSetupCheck.response(to: first, fullAccess: true)
        precondition(KeyboardSetupCheck.result(from: limited, for: first) == .limited)
        precondition(KeyboardSetupCheck.result(from: full, for: first) == .full)
        precondition(KeyboardSetupCheck.result(from: full, for: second) == nil)
        precondition(KeyboardSetupCheck.result(from: first, for: first) == nil)
        precondition(KeyboardSetupCheck.result(from: full + "typed text", for: first) == nil)
        precondition(KeyboardSetupCheck.result(from: "other text" + full, for: first) == nil)
        print("PASS keyboard setup verifies the current keyboard and distinguishes restricted and full access")
    }
}
