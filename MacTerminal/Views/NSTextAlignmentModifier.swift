import SwiftUI

extension View {
    func nsTextAlignment(_ alignment: NSTextAlignment) -> some View {
        background(NSTextAlignmentSetter(alignment: alignment))
    }
}

private struct NSTextAlignmentSetter: NSViewRepresentable {
    let alignment: NSTextAlignment

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async {
            applyAlignment(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applyAlignment(from: nsView)
        }
    }

    private func applyAlignment(from view: NSView) {
        guard let superview = view.superview else { return }
        for textField in Self.findTextFields(in: superview) {
            textField.alignment = alignment
        }
    }

    private static func findTextFields(in view: NSView) -> [NSTextField] {
        var results: [NSTextField] = []
        for sub in view.subviews {
            if let tf = sub as? NSTextField, tf.isEditable {
                results.append(tf)
            } else {
                results.append(contentsOf: findTextFields(in: sub))
            }
        }
        return results
    }
}
