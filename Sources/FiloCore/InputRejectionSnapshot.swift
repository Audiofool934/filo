import FiloPCM

/// Opt-in reference-lab evidence from the first rejected input callback.
/// Offsets describe tap callbacks, not positions in the original audio file.
public struct InputRejectionSnapshot: Encodable {
    public let available: Bool
    public let acceptedFramesBeforeCallback: UInt64
    public let callbackFrames: UInt32
    public let firstRejectedFrame: UInt32
    public let firstRejectedChannel: UInt32
    public let rejectedSampleBits: UInt32
    public let captureStartFrame: UInt32
    public let capturedFrames: UInt32
    public let sourceBits: UInt32
    public let outputBits: UInt32
    public let finite: Bool
    public let sourceRepresentable: Bool?
    public let outputRepresentable: Bool
    /// Exact Float32 bit words in stereo L/R order, including any non-finite payload.
    public let capturedSampleBits: [UInt32]

    init(_ value: FiloBridgeRejection, sampleBits: [UInt32]) {
        available = value.available
        acceptedFramesBeforeCallback = value.acceptedFramesBeforeCallback
        callbackFrames = value.callbackFrames
        firstRejectedFrame = value.firstRejectedFrame
        firstRejectedChannel = value.firstRejectedChannel
        rejectedSampleBits = value.rejectedSampleBits
        captureStartFrame = value.captureStartFrame
        capturedFrames = value.capturedFrames
        sourceBits = value.sourceBits
        outputBits = value.outputBits
        finite = value.finite
        sourceRepresentable = value.sourceBits == 0 ? nil : value.sourceRepresentable
        outputRepresentable = value.outputRepresentable
        capturedSampleBits = sampleBits
    }
}
