import UIKit

final class SwipeRow: UIView, UIGestureRecognizerDelegate {
    private let face: UIView
    private let tray: UIStackView
    private let confirm: UIButton
    private let shield = UIButton()
    private let width: CGFloat = 144
    private var initial: CGFloat = 0
    var willOpen: ((SwipeRow) -> Void)?

    init(face: UIView, actions: [UIButton], confirm: UIButton) {
        self.face = face
        self.confirm = confirm
        tray = UIStackView(arrangedSubviews: actions)
        super.init(frame: .zero)
        clipsToBounds = true; layer.cornerRadius = 7; backgroundColor = face.backgroundColor
        tray.distribution = .fillEqually
        for v in [tray, confirm, face] {
            addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor)])
        }
        face.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        tray.widthAnchor.constraint(equalToConstant: width).isActive = true
        confirm.widthAnchor.constraint(equalTo: tray.widthAnchor).isActive = true
        confirm.isHidden = true; tray.accessibilityElementsHidden = true
        shield.accessibilityLabel = ClipRelayPreferences.localized("Cancel")
        shield.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        face.addSubview(shield); shield.isHidden = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.delegate = self; addGestureRecognizer(pan)
        face.accessibilityCustomActions = actions.map { button in
            UIAccessibilityCustomAction(name: button.accessibilityLabel ?? "", actionHandler: { _ in
                guard button.isEnabled else { return false }
                button.sendActions(for: .touchUpInside); return true
            })
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); shield.frame = face.bounds }
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let speed = pan.velocity(in: self)
        return abs(speed.x) > abs(speed.y) && (face.transform.tx < 0 || speed.x < 0)
    }
    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began: initial = face.transform.tx; willOpen?(self)
        case .changed: face.transform = CGAffineTransform(translationX: max(-width, min(0, initial + pan.translation(in: self).x)), y: 0)
        case .ended:
            let speed = pan.velocity(in: self).x
            let open = abs(speed) > 180 ? speed < 0 : face.transform.tx < -width/2
            reveal(open)
        case .cancelled: reveal(initial < 0)
        default: break
        }
    }
    func close() { reveal(false) }
    func askDelete() {
        willOpen?(self); confirm.isHidden = false; tray.isHidden = true; reveal(true)
        UIAccessibility.post(notification: .layoutChanged, argument: confirm)
    }
    private func reveal(_ open: Bool) {
        shield.isHidden = !open
        tray.accessibilityElementsHidden = !open
        if !open { confirm.isHidden = true; tray.isHidden = false }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18, delay: 0, options: [.beginFromCurrentState,.allowUserInteraction]) {
            self.face.transform = CGAffineTransform(translationX: open ? -self.width : 0, y: 0)
        }
    }
}
