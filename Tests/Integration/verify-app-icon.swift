// Run against a built bundle without launching the app or accessing its preferences.
import AppKit
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
require(CommandLine.arguments.count == 2, "Provide the built AppleCam.app path")
let url = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard let bundle = Bundle(url: url) else { fatalError("Cannot read app bundle") }
require(bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon.icns", "App icon metadata")
guard let resource = bundle.url(forResource: "AppIcon", withExtension: "icns"),
      let image = NSImage(contentsOf: resource) else { fatalError("Missing or undecodable bundled icon") }
let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
let sizes = Set(bitmaps.map(\.pixelsWide))
require(Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: sizes), "Missing icon sizes: \(sizes.sorted())")
for bitmap in bitmaps {
    require(bitmap.pixelsWide == bitmap.pixelsHigh, "Icon must stay square")
    require(bitmap.hasAlpha, "Icon must retain transparency")
    require((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01, "Icon corner must be transparent")
}
print("PASS: bundled app icon resolves and decodes at standard/Retina sizes with transparent corners.")
