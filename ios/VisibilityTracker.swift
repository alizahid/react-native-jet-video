import UIKit

enum VisibilityTracker {
  /// Computes how much of `view` is actually visible on screen, walking up the
  /// superview chain and intersecting with every clipping ancestor (scroll
  /// views always clip), then with the window bounds. Returns the visible
  /// fraction (0–1), the view's prominence — how much of the *screen* its
  /// visible part covers (0–1), so a tall video clipped by its container
  /// still outranks a short one that fits entirely — and the view's rect in
  /// window coordinates (for tie-breaking). `axis` picks the formula: `.both`
  /// measures visible area; `.vertical`/`.horizontal` measure coverage along
  /// that axis only, so displacement on the other axis doesn't reduce either
  /// value while any part of the view remains on screen.
  ///
  /// A view whose screen sits under a covering modal presentation (page
  /// sheet, form sheet, full screen) counts as invisible, unless
  /// `ignorePresentation` — UIKit leaves the presenting view in the window,
  /// so geometry alone would keep a feed playing under a sheet.
  static func visibleFraction(
    of view: UIView,
    axis: VisibilityAxis = .both,
    ignorePresentation: Bool = false
  ) -> (fraction: Double, prominence: Double, windowRect: CGRect) {
    guard let window = view.window, !view.isHidden, view.alpha > 0.01 else {
      return (0, 0, .zero)
    }
    let bounds = view.bounds
    let area = bounds.width * bounds.height
    let screenArea = window.bounds.width * window.bounds.height
    guard area > 0, screenArea > 0 else {
      return (0, 0, .zero)
    }

    let windowRect = view.convert(bounds, to: nil)
    if !ignorePresentation, isCoveredByPresentation(view) {
      return (0, 0, windowRect)
    }
    var visible = bounds
    var current: UIView = view

    while let superview = current.superview {
      guard !superview.isHidden, superview.alpha > 0.01 else {
        return (0, 0, windowRect)
      }
      visible = current.convert(visible, to: superview)
      if superview.clipsToBounds || superview is UIScrollView {
        visible = visible.intersection(superview.bounds)
        if visible.isNull || visible.isEmpty {
          return (0, 0, windowRect)
        }
      }
      current = superview
    }

    // `visible` is now in window coordinates (the walk ends at the window).
    visible = visible.intersection(window.bounds)
    guard !visible.isNull, !visible.isEmpty else {
      return (0, 0, windowRect)
    }

    let visibleArea: CGFloat
    switch axis {
    case .vertical:
      visibleArea = visible.height * bounds.width
    case .horizontal:
      visibleArea = visible.width * bounds.height
    case .both:
      visibleArea = visible.width * visible.height
    }
    let clamp = { (value: CGFloat) in min(1, max(0, Double(value))) }
    return (clamp(visibleArea / area), clamp(visibleArea / screenArea), windowRect)
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
