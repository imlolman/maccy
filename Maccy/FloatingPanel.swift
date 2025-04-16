import Defaults
import SwiftUI

// An NSPanel subclass that implements floating panel traits.
// https://stackoverflow.com/questions/46023769/how-to-show-a-window-without-stealing-focus-on-macos
class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
  var isPresented: Bool = false
  var statusBarButton: NSStatusBarButton?

  override var isMovable: Bool {
    get { Defaults[.popupPosition] != .statusItem }
    set {}
  }

  init(
    contentRect: NSRect,
    identifier: String = "",
    statusBarButton: NSStatusBarButton? = nil,
    view: () -> Content
  ) {
    super.init(
        contentRect: contentRect,
        styleMask: [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )

    self.statusBarButton = statusBarButton
    self.identifier = NSUserInterfaceItemIdentifier(identifier)

    Defaults[.windowSize] = contentRect.size
    delegate = self

    animationBehavior = .none
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    minSize = NSSize(width: 300, height: 500)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    hidesOnDeactivate = false

    // Hide all traffic light buttons
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    contentView = NSHostingView(
      rootView: view()
        // The safe area is ignored because the title bar still interferes with the geometry
        .ignoresSafeArea()
        .gesture(DragGesture()
          .onEnded { _ in
            self.saveWindowFrame(frame: self.frame)
        })
    )
  }

  func toggle(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    if isPresented {
      close()
    } else {
      open(height: height, at: popupPosition)
    }
  }

  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    // Prioritize saved size, but ensure it respects minSize
    let lastSize = Defaults[.windowSize]
    var targetSize = NSSize(width: max(lastSize.width, minSize.width), 
                            height: max(lastSize.height, minSize.height))
    
    // If calculated content height is larger than saved/min height, allow expansion up to screen height
    let calculatedHeight = min(height, (NSScreen.main?.visibleFrame.height ?? 800))
    targetSize.height = max(targetSize.height, calculatedHeight) 

    print("[FloatingPanel.open] Setting initial size: \(targetSize) (saved: \(lastSize), min: \(minSize), calculated content: \(height))")
    setContentSize(targetSize)
    
    // Use saved position if available for non-statusItem modes
    var targetOrigin: NSPoint
    if popupPosition != .statusItem, let screenFrame = screen?.visibleFrame, Defaults[.windowPosition] != .zero {
        let savedRelativePos = Defaults[.windowPosition]
        targetOrigin = NSPoint(x: screenFrame.minX + (savedRelativePos.x * screenFrame.width) - (targetSize.width / 2),
                               y: screenFrame.minY + (savedRelativePos.y * screenFrame.height) - targetSize.height)
        print("[FloatingPanel.open] Using saved position: \(targetOrigin)")
    } else {
        targetOrigin = popupPosition.origin(size: targetSize, statusBarButton: statusBarButton)
        print("[FloatingPanel.open] Using calculated position: \(targetOrigin) for mode: \(popupPosition)")
    }
    setFrameOrigin(targetOrigin)

    orderFrontRegardless()
    makeKey()
    isPresented = true

    if popupPosition == .statusItem {
      DispatchQueue.main.async {
        self.statusBarButton?.isHighlighted = true
      }
    }
  }

  func verticallyResize(to newHeight: CGFloat) {
    var newSize = Defaults[.windowSize]
    // Apply minimum height constraint from minSize
    let finalHeight = max(min(newHeight, newSize.height), minSize.height)
    newSize.height = finalHeight

    var newOrigin = frame.origin
    newOrigin.y += (frame.height - newSize.height)

    print("[FloatingPanel.verticallyResize] Resizing to height: \(finalHeight) (requested: \(newHeight), maxDefault: \(Defaults[.windowSize].height), min: \(self.minSize.height))")
    NSAnimationContext.runAnimationGroup { (context) in
      context.duration = 0.2
      animator().setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }
  }

  func saveWindowFrame(frame: NSRect) {
    Defaults[.windowSize] = frame.size

    if let screenFrame = screen?.visibleFrame {
      let anchorX = frame.minX + frame.width / 2 - screenFrame.minX
      let anchorY = frame.maxY - screenFrame.minY
      Defaults[.windowPosition] = NSPoint(x: anchorX / screenFrame.width, y: anchorY / screenFrame.height)
    }
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    saveWindowFrame(frame: NSRect(origin: frame.origin, size: frameSize))

    return frameSize
  }

  // Close automatically when out of focus, e.g. outside click.
  override func resignKey() {
    super.resignKey()
    // Don't hide if confirmation is shown.
    if NSApp.alertWindow == nil {
      close()
    }
  }

  override func close() {
    super.close()
    isPresented = false
    statusBarButton?.isHighlighted = false
    
    // State reset is handled in the Popup.close() method
  }

  // Allow text inputs inside the panel can receive focus
  override var canBecomeKey: Bool {
    return true
  }
}
