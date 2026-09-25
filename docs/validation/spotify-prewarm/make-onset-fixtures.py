#!/usr/bin/env python3
"""Reproduce two original silence controls from the exact canonical filo WAV.

Only a new output directory is accepted, and existing files are never replaced.
These synthetic controls do not repair music or certify delivery of silent frames.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys


CANONICAL_SHA256 = "43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e"
FRAMES = 220500
RATE = 44100
SILENCE_NAME = "filo onset silence 44100 stereo 24bit WAV.wav"
ZERO_NAME = "filo onset warmup zeros 44100 stereo 24bit WAV.wav"
EXPECTED_HASHES = {
    SILENCE_NAME: "766217b4cb8b3f3e3365b16fcb9ab193031faa63ac26d47543e47d5ec26ed8f9",
    ZERO_NAME: "9559ec06db5fce8290d5b8923ee3ac6ff57ab16729a1bfe343c8110c9a6cfb21",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def parse_pcm24(raw):
    if len(raw) != 44 + FRAMES * 6:
        raise ValueError("Expected exactly five seconds of canonical-sized stereo PCM.")
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError("Expected RIFF/WAVE.")
    if struct.unpack_from("<I", raw, 4)[0] + 8 != len(raw):
        raise ValueError("RIFF size does not match file length.")
    chunks = []
    offset = 12
    while offset < len(raw):
        if offset + 8 > len(raw):
            raise ValueError("Truncated chunk header.")
        tag = raw[offset:offset + 4]
        size = struct.unpack_from("<I", raw, offset + 4)[0]
        start = offset + 8
        end = start + size
        if end > len(raw):
            raise ValueError("Truncated chunk payload.")
        chunks.append((tag, raw[start:end]))
        offset = end + (size & 1)
    if offset != len(raw) or [tag for tag, _ in chunks] != [b"fmt ", b"data"]:
        raise ValueError("Expected exactly fmt and data chunks, with no extra bytes.")
    fmt, pcm = chunks[0][1], chunks[1][1]
    if len(fmt) != 16 or struct.unpack("<HHIIHH", fmt) != (1, 2, RATE, RATE * 6, 6, 24):
        raise ValueError("Expected uncompressed stereo signed24 at 44100 Hz.")
    if len(pcm) != FRAMES * 6:
        raise ValueError("Unexpected sample count.")
    return pcm


def canonical_integer(frame, channel):
    """Independent integer translation of the original MIT filo test generator."""
    mask = 0xFFFFFFFF
    word = (frame & mask) ^ (((frame >> 32) * 0x85EBCA6B) & mask)
    word ^= 0xC2B2AE35 if channel else 0x27D4EB2F
    word ^= word >> 16
    word = (word * 0x7FEB352D) & mask
    word ^= word >> 15
    word = (word * 0x846CA68B) & mask
    word ^= word >> 16
    return (word & 16383) - 8192


def read_canonical(path):
    # Bound the read before checking the exact hash and each generated integer.
    with path.open("rb") as source:
        raw = source.read(44 + FRAMES * 6 + 1)
    if digest(raw) != CANONICAL_SHA256:
        raise ValueError("Reference SHA-256 differs from the canonical original.")
    pcm = parse_pcm24(raw)
    for frame in range(FRAMES):
        for channel in range(2):
            offset = (frame * 2 + channel) * 3
            observed = int.from_bytes(pcm[offset:offset + 3], "little", signed=True)
            if observed != canonical_integer(frame, channel):
                raise ValueError(f"Canonical integer mismatch at frame {frame}, channel {channel}.")
    return pcm


def wav_bytes(pcm):
    if len(pcm) != FRAMES * 6:
        raise ValueError("Fixture payload must contain exactly 220500 frames.")
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, 2, RATE, RATE * 6, 6, 24)
            + b"data" + struct.pack("<I", len(pcm)) + pcm)


def generate(reference, output_dir):
    if output_dir.exists() or output_dir.is_symlink():
        raise ValueError("Output directory already exists; choose a new directory.")
    canonical = read_canonical(reference)
    silence_payload = bytes(RATE * 6) + canonical[:(FRAMES - RATE) * 6]
    payloads = {SILENCE_NAME: silence_payload, ZERO_NAME: bytes(FRAMES * 6)}
    encoded = {name: wav_bytes(payload) for name, payload in payloads.items()}
    for name, raw in encoded.items():
        if parse_pcm24(raw) != payloads[name] or digest(raw) != EXPECTED_HASHES[name]:
            raise ValueError(f"Internal fixture validation failed: {name}")

    # mkdir is exclusive. Validation finishes before any destination is created.
    output_dir.mkdir(mode=0o700)
    files = []
    for name, raw in encoded.items():
        path = output_dir / name
        with path.open("xb") as output:
            output.write(raw)
        stored = path.read_bytes()
        if stored != raw or parse_pcm24(stored) != payloads[name]:
            raise ValueError(f"Written fixture did not validate: {name}")
        files.append({"name": name, "fileSHA256": digest(stored), "frames": FRAMES,
                      "pcm24SHA256": digest(payloads[name])})
    return {"referenceSHA256": CANONICAL_SHA256, "canonicalIntegerSamplesVerified": FRAMES * 2,
            "sampleRate": RATE, "channels": 2, "bitsPerSample": 24, "files": files,
            "scope": "Original synthetic controls only; source silence cannot certify its own delivery."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="A new directory whose parent already exists; existing directories are refused.")
    args = parser.parse_args()
    try:
        result = generate(args.reference, args.output_dir)
    except (OSError, ValueError) as error:
        print(f"make-onset-fixtures: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
