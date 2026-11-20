#if os(macOS)
import Combine
import SwiftUI

struct MacActionFeedback {
    let target: String
    let message: String
}

private struct MacActionAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

extension View {
    func macFeedbackTarget(_ target: String) -> some View {
        anchorPreference(key: MacActionAnchors.self, value: .bounds) { [target: $0] }
    }

    func macFeedbackOverlay(_ feedback: MacActionFeedback?,
                            copyConfirmation: PassthroughSubject<String, Never>? = nil) -> some View {
        overlayPreferenceValue(MacActionAnchors.self) { anchors in
            if let feedback, let anchor = anchors[feedback.target] {
                GeometryReader { geometry in
                    let button = geometry[anchor]
                    let size = geometry.size
                    if button.intersects(CGRect(origin: .zero, size: size)) {
                        let above = button.midY > size.height / 2
                        let width = min(300, max(0, size.width - 16))
                        let x = min(max(8, button.maxX - width), max(8, size.width - width - 8))
                        Text(verbatim: feedback.message)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
                            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
                            .frame(width: width, alignment: .trailing)
                            .padding(.leading, x)
                            .padding(above ? .bottom : .top, above ? size.height - button.minY + 5 : button.maxY + 5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: above ? .bottomLeading : .topLeading)
                            .accessibilityIdentifier("mac.action.feedback")
                    }
                }
                .allowsHitTesting(false)
            }
            if let copyConfirmation {
                GeometryReader { geometry in
                    MacCopyFeedback(confirmation: copyConfirmation) { target in
                        guard let anchor = anchors[target] else { return nil }
                        let rect = geometry[anchor]
                        let visible = rect.intersection(CGRect(origin: .zero, size: geometry.size))
                        return visible.isEmpty ? nil : visible
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

private struct MacCopyFeedback: View {
    let confirmation: PassthroughSubject<String, Never>
    let frameForTarget: (String) -> CGRect?
    @State private var toast: Toast?

    private struct Toast {
        let id = UUID()
        let frame: CGRect
    }

    var body: some View {
        Color.clear
            .overlay {
                if let toast {
                    MacCopyToastPlacement(target: toast.frame) {
                        MacCopyToast(animateCheck: true).fixedSize().id(toast.id)
                    }
                }
            }
            .onReceive(confirmation) { target in
                // Keep the action's position if copying removes the row.
                guard let frame = frameForTarget(target) else { return }
                toast = Toast(frame: frame)
            }
            .task(id: toast?.id) {
                guard let id = toast?.id else { return }
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                if toast?.id == id { toast = nil }
            }
    }
}

private struct MacCopyToastPlacement: Layout {
    let target: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let toast = subviews.first else { return }
        let size = toast.sizeThatFits(.unspecified)
        let inset: CGFloat = 8
        let below = target.maxY + 6
        let above = target.minY - 6 - size.height
        let x = max(inset, min(target.maxX - size.width, bounds.width - size.width - inset))
        let y = max(inset, min(below + size.height <= bounds.height - inset ? below : above,
                               bounds.height - size.height - inset))
        toast.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
    }
}
#endif
