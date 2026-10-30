import AppKit

enum MenuBarIcon {
    /// Silhouette of the app icon (round mouth, throat, uvula, lower lip) drawn as a template image
    /// so macOS tints it for light/dark menu bars.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15)).fill()

            // Throat: an arch whose floor is the top of the lower lip, dipping in the middle.
            let throat = NSBezierPath()
            throat.move(to: NSPoint(x: 3.0, y: 5.4))
            throat.curve(to: NSPoint(x: 9, y: 14.0), controlPoint1: NSPoint(x: 2.4, y: 10.6), controlPoint2: NSPoint(x: 5.0, y: 14.0))
            throat.curve(to: NSPoint(x: 15.0, y: 5.4), controlPoint1: NSPoint(x: 13.0, y: 14.0), controlPoint2: NSPoint(x: 15.6, y: 10.6))
            throat.curve(to: NSPoint(x: 9, y: 6.9), controlPoint1: NSPoint(x: 13.6, y: 7.2), controlPoint2: NSPoint(x: 11.0, y: 7.8))
            throat.curve(to: NSPoint(x: 3.0, y: 5.4), controlPoint1: NSPoint(x: 7.0, y: 7.8), controlPoint2: NSPoint(x: 4.4, y: 7.2))
            throat.close()
            context.compositingOperation = .clear
            throat.fill()

            // Uvula: drops from the top of the arch through a slim neck into a rounded bulb.
            let uvula = NSBezierPath()
            uvula.move(to: NSPoint(x: 7.4, y: 14.4))
            uvula.curve(to: NSPoint(x: 8.4, y: 11.8), controlPoint1: NSPoint(x: 8.2, y: 13.9), controlPoint2: NSPoint(x: 8.4, y: 12.8))
            uvula.curve(to: NSPoint(x: 9, y: 8.4), controlPoint1: NSPoint(x: 7.2, y: 10.6), controlPoint2: NSPoint(x: 7.4, y: 8.4))
            uvula.curve(to: NSPoint(x: 9.6, y: 11.8), controlPoint1: NSPoint(x: 10.6, y: 8.4), controlPoint2: NSPoint(x: 10.8, y: 10.6))
            uvula.curve(to: NSPoint(x: 10.6, y: 14.4), controlPoint1: NSPoint(x: 9.6, y: 12.8), controlPoint2: NSPoint(x: 9.8, y: 13.9))
            uvula.close()
            context.compositingOperation = .sourceOver
            uvula.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Throat"
        return image
    }()
}
