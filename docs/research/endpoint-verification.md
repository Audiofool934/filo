# Endpoint verification research

Research date: 2026-09-23.
Scope: an Apple Silicon Mac with the existing Sony NW-ZX706 in USB-DAC mode, without additional test hardware, driver installation, or security-policy changes.
This investigation used documentation, source inspection, and read-only host diagnostics.
It did not play or record audio, change an audio setting, or access a subscription master.

## Finding

The strongest immediately available experiment is an independently generated reference file compared with the actual buffers submitted to the physical WALKMAN output, with the player, routing, sample rate, channel layout, and exclusivity conditions recorded.
That experiment can establish sample identity through the measured host boundary.
It cannot by itself establish what the WALKMAN USB receiver received, because the buffer being submitted and the receiver are different observation points.

No currently enabled USB payload capture interface was found on this Mac.
No documented NW-ZX706 received-sample checksum, PCM readback, or known-pattern bit-test facility was found in the Sony sources reviewed.
These are bounded findings about the available interfaces and reviewed documentation, not a claim that undocumented diagnostics or future facilities cannot exist.

The next version should distinguish a tested transparent playback path from independently measured endpoint evidence.
A successful local test should retain its exact boundary and conditions instead of turning into an unconditional indicator for every subsequent subscription track.

## Sony endpoint

Sony documents the USB-DAC display as showing signal presence, PCM/DSD type, sampling frequency, and quantization bit depth.
The documented display does not compare sample values against a reference.
Consequently, a matching 192 kHz / 24-bit display is useful format evidence but is not a sample-integrity result.
See [Sony USB-DAC screen](https://helpguide.sony.net/dmp/1302/v1/en/contents/TP1000731800.html).

The [NW-ZX706/NW-ZX707 Help Guide](https://helpguide.sony.net/dmp/1302/v1/en/print.pdf), pages 110-112 and 137, describes USB-DAC operation, sound processing, and physical interfaces.
Sony says the player's sound adjustments also apply in USB-DAC mode and describes processing before headphone playback.
The listed audio connectors are stereo and balanced headphone outputs; the reviewed guide does not document an S/PDIF output or a simultaneous USB-DAC-input-to-digital-output monitor.
USB audio output to another device is a separate use case, not evidence that the incoming USB-DAC stream is available for readback.
No bit-test feature was located in this guide.
This rules out relying on a documented Sony self-test for the current validation plan, while leaving a vendor diagnostic query as a possible later research avenue.

The intended endpoint must be explicit: USB audio samples arriving at the WALKMAN input are a sensible digital boundary.
The headphone signal is analog and the WALKMAN may intentionally process audio after receipt, so analog waveform similarity cannot substitute for digital sample equality.

Read-only I/O Registry inspection of the currently connected WALKMAN returned `UsbLinkSpeed = 480000000`, `USBSpeed = 3`, `Device Speed = 2`, and `bcdUSB = 0x0210`.
The host-family speed enumeration defines `kIOUSBHostConnectionSpeedHigh = 3`; the older USB enumeration instead defines `kUSBDeviceSpeedHigh = 2`.
These values describe the same observed 480 Mb/s connection, not a contradiction.
The definitions were checked in the installed SDK's `IOUSBHostFamilyDefinitions.h` and `USB.h`.
Device serial numbers and persistent UIDs were excluded from the diagnostic output.

## What each measurement establishes

| Boundary | Required observation | Valid conclusion | Remaining gap |
| --- | --- | --- | --- |
| Reference to player tap | Known reference PCM and captured application output | The tested player configuration preserved samples up to the tap | Output callback, driver, USB, receiver |
| Reference to physical output callback | Independent reference and actual outgoing buffers, plus format/rate checks | The measured buffers submitted to the WALKMAN path match | Driver packing, USB transport, receiver |
| Virtual digital loopback | Capture of the rendered virtual-device input | The tested software route including virtual rendering preserved samples | Different physical driver and actual WALKMAN |
| Host USB transfer buffer | Actual transfer bytes and completion records from an instrumented transport | The host submitted the expected USB payload | Independent observation of bus delivery and receiver behavior |
| Inline USB analyzer | Complete bus capture adjacent to the WALKMAN | The on-wire payload addressed to the WALKMAN matches the reference | Internal receiver and post-USB processing |
| Receiver-side test | Firmware comparison/readback at a documented input point | Samples at that receiver boundary match | Only processing after that point |

The existing [1.0 validation](../VALIDATION.md) reaches the tap and virtual-loopback boundaries.
Its WALKMAN experiment does not include an independent USB capture.

## Software USB capture on this Mac

On the research date, `/usr/sbin/tcpdump -D` and `/sbin/ifconfig -l` reported no `XHC` or other USB capture interface.
`/usr/bin/csrutil status` reported System Integrity Protection enabled.
No interface was enabled, no packet capture was started, and no privilege escalation was attempted.

Wireshark documents an older macOS `XHC20` capture path, but places software USB captures at the USB-request boundary rather than the raw on-wire transaction boundary.
Its current capture guide also notes the SIP restriction on Catalina and later.
See [Wireshark USB capture setup](https://wiki.wireshark.org/CaptureSetup/USB).

Apple DTS confirmed in 2019 that this capture support became disabled by default and required disabling SIP.
That is historical confirmation, not a promise that disabling SIP enables capture on the present OS.
The same thread contains a 2025 user report of failure on macOS 15.6.1 even with SIP disabled and a 2026 unresolved question about recent systems.
Those later posts are reports by forum participants, not Apple confirmation.
See [Apple Developer Forums discussion](https://developer.apple.com/forums/thread/124875).

The documented `IOUSBHostObjectInitOptions.deviceCapture` option is easily misread.
It captures ownership by terminating existing drivers and clients; it is not a passive traffic sniffer.
Apple requires root privileges or a specific entitlement and authorization for that operation.
Using it would replace the current Apple USB Audio route and reset the device when relinquished, rather than provide an independent observation of the unchanged route.
See [Apple deviceCapture documentation](https://developer.apple.com/documentation/iousbhost/iousbhostobjectinitoptions/devicecapture).

Writing a user-space USB Audio transport could make the outgoing transfer buffers inspectable, but it would also require device ownership, descriptor and alternate-setting handling, rate/clock controls, asynchronous feedback handling, queue scheduling, and robust teardown.
It is a different transport implementation and still provides host-side evidence unless a receiver or analyzer supplies an independent observation.
The general driver framework is documented in [IOUSBHost](https://developer.apple.com/documentation/iousbhost/).

USB audio feedback is clock/rate information, not an echo or checksum of received samples.
Apple describes explicit and implicit feedback in [TN3190](https://developer.apple.com/documentation/technotes/tn3190-usb-audio-device-design-considerations).
Transfer completion and a healthy feedback rate therefore must not be presented as a receiver-side sample comparison.
Apple's [USB device overview](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/USBBook/USBOverview/USBOverview.html) also distinguishes the retry behavior of isochronous audio transfers from other transfer types.

No supported, passive, unprivileged API for independently capturing the existing Apple USB Audio payload was identified in the reviewed Apple documentation.
The present plan should not depend on such an API appearing later in implementation.

## Strongest practical plan without more hardware

1. Generate an original deterministic stereo WAV reference with independent channel identifiers, frame identity, low-bit variation, signed boundaries, and a documented canonical integer representation.
2. Play the fixture through Music, not only through filo's synthetic emitter, to measure the real application's decode/output path.
3. Compare all expected content against the tap, then compare the actual final outgoing buffers against that same reference before submitting them to the physical output.
4. Record exact valid bits, container size, alignment, interleaving, stream/nominal rates, channel map, output-device identity, ownership, callback continuity, and the first mismatch.
5. Allow a fixed startup latency, but require a defined start/end marker and complete content coverage so that a correct middle excerpt cannot hide a lost beginning or ending.
6. Treat rate changes as separate verified stream segments; test both upward and downward transitions and refuse a transparent-path status during uncertain or mismatched intervals.
7. Test deliberate gain, channel swapping, bit truncation, dropped/repeated frames, and inserted silence so that the verifier demonstrates rejection rather than merely successful self-comparison.
8. Publish a bounded receipt with the reference hash, comparator version, exact measured boundary, compared frame count, mismatch count, host/app/device versions, and unmet endpoint-observation condition.

Use the existing quiet pattern for tests that can reach headphones.
A full-range bit-walking pattern is valuable for representation coverage but requires a physically inaudible test arrangement, such as disconnected headphones, before playback.
This is a test-level requirement, not a reason to raise listening volume.

There must be independent reference construction or independent parser checks to avoid the producer and verifier sharing the same packing bug.
Lossless representation changes may be normalized to canonical integers, but the normalization must be mathematically defined and must not apply gain matching, dither, resampling, or arbitrary realignment.
Container padding should be checked separately from the significant sample bits.

Subscription tracks lack an independently available reference in the current project.
A test using a locally owned fixture can validate a configured path, but does not establish that an unrelated subscription master, track variant, or future player behavior has identical samples.
Live route invariants can preserve confidence in that tested configuration while honestly separating them from a new per-track comparison.

## Hardware options if available later

An inline USB analyzer is the most direct extension for this specific WALKMAN.
For the observed high-speed USB connection, a USB 2.0 analyzer that captures isochronous payloads without truncation is sufficient in principle.
For example, the [Beagle USB 480](https://www.totalphase.com/products/beagle-usb480/) supports low/full/high-speed capture and a host API; its [manual](https://www.totalphase.com/support/articles/200472426-beagle-protocol-analyzer-user-manual/) describes transparent pass-through and overflow behavior.
Requirements are the analyzer, the correct USB cable/adapter arrangement, a compatible capture host, complete descriptor/control/data capture, and an exporter/parser that preserves payload bytes and capture errors.
A separate capture host is preferable where available.
Capture loss or overflow must invalidate the affected measurement.

The decoder must reconstruct selected-interface audio OUT payloads using the captured descriptors and active settings, separating feedback from audio and respecting valid-bit alignment and channel order.
Packet boundaries are not audio-frame boundaries and asynchronous feedback can vary the number of samples per packet.
The normative starting point is the [USB-IF Audio 2.0 specification package](https://www.usb.org/document-library/audio-devices-rev-20-and-adopters-agreement).

An RME ADI-2 with the documented Bit Test and RME's corresponding test WAVs is another useful validation endpoint.
The [RME manual, Bit Test section](https://archiv.rme-audio.de/download/adi2dac_e.pdf) describes detection of an internal known pattern and the classes of corruption it checks.
Passing that test would validate delivery to that RME receiver, not prove the Sony path.
No such device is currently available for this project.

A USB-to-S/PDIF device plus a verified digital input or hardware S/PDIF decoder can validate a different physical output route.
It does not observe the WALKMAN USB input and should not be reported as Sony endpoint evidence.

## Open-source methods inspected

[jwhitham/spdif-bit-exactness-tools](https://github.com/jwhitham/spdif-bit-exactness-tools) has actual source for generating identifiable bit patterns and checking an independently received S/PDIF signal.
The inspected [generator](https://github.com/jwhitham/spdif-bit-exactness-tools/blob/master/siggen.c) combines bit walking, a marker, and channel-specific payload values.
Its [oscilloscope decoder](https://github.com/jwhitham/spdif-bit-exactness-tools/blob/master/oscilloscope/sigtest.py) operates on a separately captured physical signal.
The transferable design lesson is to observe a boundary independently and use patterns that expose channel/bit corruption.
Its hardware requirements do not disappear when applying the method to filo.

[orenskl/bitperfect](https://github.com/orenskl/bitperfect/blob/main/bitperfect.py) compares two WAV arrays after aligning each to its first nonzero frame and rejects differing sample rates.
This is an accessible example of exact comparison, but it is a comparator, not a capture method.
Its source does not establish where the second WAV was measured or certify a DAC.
Its simple first-nonzero alignment also motivates explicit start/end coverage in filo's stricter experiment.

No third-party code was copied into filo during this research.
