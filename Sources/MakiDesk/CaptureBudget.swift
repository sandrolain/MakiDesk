import Foundation

/// What the screenshot path may hold in memory (R06).
///
/// Two caches hold pixels: the window capture cache that feeds every consumer,
/// and the palette's own copy of the previews it is showing. The second cannot
/// be smaller than what the first hands out, and both are measured in bytes
/// rather than entries, because one 4K window costs more than forty small ones.
///
/// The numbers are here so that a new consumer — the shelf's thumbnails, the
/// focus veil — takes a share of one total instead of inventing its own.
enum CaptureBudget {
    /// Everything the capture path may hold at rest.
    static let totalBytes = 96 * 1024 * 1024

    /// The capture cache: the source every consumer reads from.
    static let cacheBytes = totalBytes * 2 / 3

    /// The palette's images, held apart because the cards keep them after the
    /// capture has been evicted.
    static let paletteBytes = totalBytes - cacheBytes
}
