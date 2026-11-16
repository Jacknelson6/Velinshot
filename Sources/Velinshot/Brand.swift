import AppKit

enum Brand {
    static let iris = NSColor(srgbRed: 0.443, green: 0.376, blue: 0.910, alpha: 1)
    static let ink = NSColor(srgbRed: 0.098, green: 0.102, blue: 0.145, alpha: 1)
    static func symbol(_ name: String, size: CGFloat = 16) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .labelColor
        return label
    }
    static func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if let symbol { button.image = self.symbol(symbol); button.imagePosition = .imageLeading }
        return button
    }
}

final class ActionButton: NSButton {
    var actionHandler: (() -> Void)?
    convenience init(title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        bezelStyle = .rounded
        if let symbol { image = Brand.symbol(symbol); imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        actionHandler = action
        target = self
        self.action = #selector(invoke)
    }
    @objc private func invoke() { actionHandler?() }
}

extension NSView {
    func pin(to view: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: view.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset)
        ])
    }
}
