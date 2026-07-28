import UIKit

enum VisibilityTracker {
  /// Computes how much of `view` is actually visible on screen, walking up the
  /// superview chain and intersecting with every clipping ancestor (scroll
  /// views always clip), then with the window bounds. Returns the visible
  /// fraction of the view's area (0–1) and the view's rect in window
  /// coordinates (for tie-breaking).
  static func visibleFraction(of view: UIView) -> (fraction: Double, windowRect: CGRect) {
    guard let window = view.window, !view.isHidden, view.alpha > 0.01 else {
      return (0, .zero)
    }
    let bounds = view.bounds
    let area = bounds.width * bounds.height
    guard area > 0 else {
      return (0, .zero)
    }

    let windowRect = view.convert(bounds, to: nil)
    var visible = bounds
    var current: UIView = view

    while let superview = current.superview {
      guard !superview.isHidden, superview.alpha > 0.01 else {
        return (0, windowRect)
      }
      visible = current.convert(visible, to: superview)
      if superview.clipsToBounds || superview is UIScrollView {
        visible = visible.intersection(superview.bounds)
        if visible.isNull || visible.isEmpty {
          return (0, windowRect)
        }
      }
      current = superview
    }

    // `visible` is now in window coordinates (the walk ends at the window).
    visible = visible.intersection(window.bounds)
    guard !visible.isNull, !visible.isEmpty else {
      return (0, windowRect)
    }

    let fraction = Double((visible.width * visible.height) / area)
    return (min(1, max(0, fraction)), windowRect)
  }
}
