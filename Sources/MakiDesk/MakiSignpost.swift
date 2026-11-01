import os

/// Intervals for Instruments (R11).
///
/// The log carries counts and durations, but it cannot show *where* a second
/// went when two things overlap. These intervals are cheap when nobody is
/// recording, and they are the numbers N13 and N15 were being argued about
/// without a measurement.
///
/// Nothing here talks to the network, reads a window or writes a file: an
/// interval has a name, an id and nothing else, so it cannot leak a title.
enum MakiSignpost {
    /// Accessibility work: discovery and the frame writes (N13).
    static let index = OSSignposter(logger: MakiLog.index)
    /// Text recognition: the Vision request (N15's neighbour).
    static let ocr = OSSignposter(logger: MakiLog.ocr)

    /// The name of the frame-write interval, in one place so the begin and the
    /// end cannot disagree.
    static let frameWrite: StaticString = "frame write"
    static let recognition: StaticString = "recognise text"
}
