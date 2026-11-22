/// The Dock's own window covers the whole screen and macOS only reveals its
/// icon frames through Accessibility, so without that permission its width is
/// estimated from what the Dock shows. Fitted to two measured Docks on
/// macOS 27: 20 items at 44 pt tiles ≈ 938 pt (SnowDesk's calibration) and
/// 22 items at 70 pt tiles = 1564 pt (measured on this Mac).
public enum DockGeometry {
    /// - Parameters:
    ///   - inset: bottom inset of the screen's visible frame (Dock area height), points.
    ///   - items: number of icons (apps, recents, folders, Trash).
    ///   - separators: number of Dock separators.
    ///   - screenWidth: width of the Dock's screen, points.
    /// - Returns: the Dock platter's x offset from the screen's left and its width,
    ///   or nil when the Dock is hidden or not at the bottom.
    public static func estimate(inset: Float, items: Int, separators: Int, screenWidth: Float) -> (x: Float, width: Float)? {
        guard inset >= 20, items > 0 else { return nil }
        let tile = inset - 20
        let w = min(Float(items) * (tile * 0.935 + 4.35) + Float(separators) * 12 + 16, screenWidth)
        return ((screenWidth - w) / 2, w)
    }
}
