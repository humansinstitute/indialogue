import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.20, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
NSColor(calibratedRed: 0.96, green: 0.25, blue: 0.27, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 132, y: 132, width: 760, height: 760)).fill()
let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!
let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .medium).applying(.init(paletteColors: [.white]))
symbol.withSymbolConfiguration(config)!.draw(in: NSRect(x: 300, y: 254, width: 424, height: 516))
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Recorder/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
