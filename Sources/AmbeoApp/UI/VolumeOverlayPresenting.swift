import Foundation

/// AppModel presents the OSD through this protocol so tests can record presentations instead of
/// opening a real NSPanel. `VolumeOverlayManager` is the production implementation.
@MainActor protocol VolumeOverlayPresenting: AnyObject {
  func show(_ update: (VolumeOverlayState) -> Void)
}

extension VolumeOverlayManager: VolumeOverlayPresenting {}
