import AppKit
// Full-bleed macOS icon: exact brand logo on the website's cream (#F3F1E9).
let logo = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
for (name, px) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  let s = CGFloat(px)
  NSColor(srgbRed: 0x17/255.0, green: 0x54/255.0, blue: 0x4F/255.0, alpha: 1).setFill()
  NSRect(x: 0, y: 0, width: s, height: s).fill()
  let inset = s * 0.09
  let r = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
  // Solid cream underlay in the logo's own shape, so its translucent faces keep
  // the colours they have on the website's cream page.
  let under = NSImage(size: logo.size)
  under.lockFocus()
  for _ in 0..<8 { logo.draw(in: NSRect(origin: .zero, size: logo.size), from: .zero, operation: .sourceOver, fraction: 1) }
  NSColor(srgbRed: 0xF3/255.0, green: 0xF1/255.0, blue: 0xE9/255.0, alpha: 1).set()
  NSRect(origin: .zero, size: logo.size).fill(using: .sourceAtop)
  under.unlockFocus()
  under.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
  logo.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("ok")
