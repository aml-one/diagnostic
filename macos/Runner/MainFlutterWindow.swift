import Cocoa
import FlutterMacOS
import Metal

/// Flutter 3.41's macOS rasterizer is Metal-only. Impeller is already off by
/// default on desktop; `FLTEnableImpeller=false` does not change the engine
/// switches. Skia-on-Metal (and Impeller, if forced) null-deref on GPU family
/// Mac1 — Intel HD 4000/5000, e.g. MacBookAir6,2 / HD Graphics 5000.
/// Mac2 is 2015+ Iris or any Apple Silicon.
enum AowMacMetal {
  static func preferredDevice() -> MTLDevice? {
    let devices = MTLCopyAllDevices()
    for device in devices where device.hasUnifiedMemory {
      return device
    }
    return MTLCreateSystemDefaultDevice()
  }

  static func canHostFlutter() -> Bool {
    guard let device = preferredDevice() else { return false }
    return device.supportsFamily(.mac2)
  }

  static var gpuName: String {
    preferredDevice()?.name ?? "no Metal GPU"
  }
}

/// Shown instead of `FlutterViewController` so Intel HD 5000 never enters
/// `viewWillAppear` → engine start → SIGSEGV at 0x6b8.
final class UnsupportedGpuViewController: NSViewController {
  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor(
      calibratedRed: 0.984, green: 0.980, blue: 1.0, alpha: 1
    ).cgColor

    let title = label(
      "This Mac cannot run AOW Diagnostic",
      size: 22,
      weight: .bold,
      color: NSColor(calibratedRed: 0.102, green: 0.078, blue: 0.188, alpha: 1)
    )
    let body = label(
      "Flutter needs Metal GPU family Mac2 (2015 or newer Intel Iris, or Apple Silicon).\n\nThis computer reports \(AowMacMetal.gpuName), which is Mac1. Opening the Flutter engine crashes instantly on macOS 11 with that GPU.\n\nUse Diagnostic on Windows, Linux, or a 2015-or-newer Mac.",
      size: 14,
      weight: .regular,
      color: NSColor(calibratedRed: 0.420, green: 0.388, blue: 0.565, alpha: 1)
    )
    body.preferredMaxLayoutWidth = 520

    let stack = NSStackView(views: [title, body])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 40),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
    ])

    self.view = root
  }

  private func label(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor
  ) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = NSFont.systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.backgroundColor = .clear
    field.isBezeled = false
    field.isEditable = false
    field.alignment = .left
    return field
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let windowFrame = self.frame
    if AowMacMetal.canHostFlutter() {
      let flutterViewController = FlutterViewController()
      self.contentViewController = flutterViewController
      RegisterGeneratedPlugins(registry: flutterViewController)
    } else {
      NSLog(
        "AOW Diagnostic: skipping Flutter on %@. Metal family Mac2 is required.",
        AowMacMetal.gpuName
      )
      self.title = "AOW Diagnostic"
      self.contentViewController = UnsupportedGpuViewController()
    }
    self.setFrame(windowFrame, display: true)
    super.awakeFromNib()
  }
}
