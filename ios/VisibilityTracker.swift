import UIKit

enum VisibilityTracker {
  /// Computes how much of `view` is actually visible on screen, walking up the
  /// superview chain and intersecting with every clipping ancestor (scroll
  /// views always clip), then with the window bounds. Returns the visible
  /// fraction (0–1) and the view's rect in window coordinates (for
  /// tie-breaking). `axis` picks the formula: `.both` measures visible area;
  /// `.vertical`/`.horizontal` measure coverage along that axis only, so
  /// displacement on the other axis doesn't reduce the fraction while any
  /// part of the view remains on screen.
  ///
  /// A view whose screen sits under a covering modal presentation (page
  /// sheet, form sheet, full screen) counts as invisible, unless
  /// `ignorePresentation` — UIKit leaves the presenting view in the window,
  /// so geometry alone would keep a feed playing under a sheet.
  static func visibleFraction(
    of view: UIView,
    axis: VisibilityAxis = .both,
    ignorePresentation: Bool = false
  ) -> (fraction: Double, windowRect: CGRect) {
    guard let window = view.window, !view.isHidden, view.alpha > 0.01 else {
      return (0, .zero)
    }
    let bounds = view.bounds
    let area = bounds.width * bounds.height
    guard area > 0 else {
      return (0, .zero)
    }

    let windowRect = view.convert(bounds, to: nil)
    if !ignorePresentation, isCoveredByPresentation(view) {
      return (0, windowRect)
    }
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

    let fraction: Double
    switch axis {
    case .vertical:
      fraction = Double(visible.height / bounds.height)
    case .horizontal:
      fraction = Double(visible.width / bounds.width)
    case .both:
      fraction = Double((visible.width * visible.height) / area)
    }
    return (min(1, max(0, fraction)), windowRect)
  }

  private static func isCoveredByPresentation(_ view: UIView) -> Bool {
    // `presentedViewController` is forwarded from ancestors, so the nearest
    // controller answers for its whole presentation layer.
    guard let presented = view.nearestViewController?.presentedViewController,
          !presented.isBeingDismissed,
          !(presented is UIAlertController) else {
      return false
    }
    switch presented.modalPresentationStyle {
    case .overFullScreen, .overCurrentContext, .popover, .custom, .none:
      // Transparent or partial presentations leave the content in view.
      return false
    default:
      return true
    }
  }
}
