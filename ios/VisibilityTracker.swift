import UIKit

enum VisibilityTracker {
  /// Computes how much of `view` is actually visible on screen, walking up the
  /// superview chain and intersecting with every clipping ancestor (scroll
  /// views always clip, minus the strips under their adjusted content insets),
  /// then with the window bounds. Returns the visible fraction (0–1, relative
  /// to what the layout shows of the view — see `design` below), the view's
  /// prominence — how much of the *screen* its visible part covers (0–1) —
  /// and the view's rect in window coordinates (for tie-breaking). `axis` picks the formula: `.both`
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
    let screenArea = window.bounds.width * window.bounds.height
    guard bounds.width > 0, bounds.height > 0, screenArea > 0 else {
      return (0, 0, .zero)
    }

    let windowRect = view.convert(bounds, to: nil)
    if !ignorePresentation, isCoveredByPresentation(view) {
      return (0, 0, windowRect)
    }
    // `visible` is what's actually on screen; `design` is what the layout
    // means to show — the view clipped by its non-scrolling ancestors (an
    // `overflow: hidden` cell) but never by scrolling. The fraction is
    // measured against the design rect: a tall video its cell crops to half
    // the screen is 100% visible while the cell is, and 50% once half the
    // cell has scrolled under a header.
    var visible = bounds
    var design = bounds
    var current: UIView = view
    // Clipping above the first scroll view is the viewport (the scroll
    // view's own container, the screen), not the layout — it must not shrink
    // the design rect or a video scrolling off would measure against the
    // part still on screen.
    var insideScrollView = true

    while let superview = current.superview {
      guard !superview.isHidden, superview.alpha > 0.01 else {
        return (0, 0, windowRect)
      }
      visible = current.convert(visible, to: superview)
      design = current.convert(design, to: superview)
      if let scrollView = superview as? UIScrollView {
        // Content under a scroll view's adjusted insets sits behind bars (a
        // transparent header, a translucent tab bar): on screen
        // geometrically, but not to the user.
        visible = visible.intersection(scrollView.bounds.inset(by: scrollView.adjustedContentInset))
        insideScrollView = false
      } else if superview.clipsToBounds {
        visible = visible.intersection(superview.bounds)
        if insideScrollView {
          design = design.intersection(superview.bounds)
        }
      }
      if visible.isNull || visible.isEmpty {
        return (0, 0, windowRect)
      }
      current = superview
    }

    // Both rects are now in window coordinates (the walk ends at the window).
    visible = visible.intersection(window.bounds)
    guard !visible.isNull, !visible.isEmpty else {
      return (0, 0, windowRect)
    }

    let visibleArea: CGFloat
    let designArea: CGFloat
    switch axis {
    case .vertical:
      visibleArea = visible.height * design.width
      designArea = design.height * design.width
    case .horizontal:
      visibleArea = visible.width * design.height
      designArea = design.width * design.height
    case .both:
      visibleArea = visible.width * visible.height
      designArea = design.width * design.height
    }
    guard designArea > 0 else {
      return (0, 0, windowRect)
    }
    let clamp = { (value: CGFloat) in min(1, max(0, Double(value))) }
    return (clamp(visibleArea / designArea), clamp(visibleArea / screenArea), windowRect)
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
