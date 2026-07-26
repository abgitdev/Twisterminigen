#!/usr/bin/env python3
"""Compute a deterministic Mach-O digest independent of its current code signature.

For every thin slice, the digest covers every byte before LC_CODE_SIGNATURE while canonicalizing
the signing-dependent load-command fields (the signature offset/size and __LINKEDIT size fields).
For a universal binary, slice offsets and signed sizes in the fat header are deliberately replaced
by each slice's architecture identity and normalized digest. No copy is executed or re-signed.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import struct
import sys
from pathlib import Path


DOMAIN = b"TwisterminigenSigningNormalizedMachOV1\0"
LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def stable_regular_file(path: Path) -> tuple[bytes, int]:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"cannot open executable {path}: {error}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            fail(f"executable must be a regular file: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    except OSError as error:
        fail(f"cannot read executable {path}: {error}")
    finally:
        os.close(descriptor)
    identity_before = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    identity_after = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    )
    try:
        current = os.stat(path, follow_symlinks=False)
    except OSError as error:
        fail(f"cannot recheck executable {path}: {error}")
    if (
        identity_before != identity_after
        or not stat.S_ISREG(current.st_mode)
        or (current.st_dev, current.st_ino) != (after.st_dev, after.st_ino)
    ):
        fail(f"executable changed while it was being read: {path}")
    payload = b"".join(chunks)
    if len(payload) != after.st_size:
        fail(f"executable size changed while it was being read: {path}")
    return payload, stat.S_IMODE(after.st_mode)


def unpack_u32(payload: bytes | bytearray, offset: int, endian: str) -> int:
    try:
        return struct.unpack_from(endian + "I", payload, offset)[0]
    except struct.error:
        fail("Mach-O contains a truncated 32-bit field")


def normalized_thin_slice(payload: bytes) -> tuple[int, int, bytes]:
    magic = payload[:4]
    thin_formats = {
        b"\xce\xfa\xed\xfe": ("<", False),
        b"\xcf\xfa\xed\xfe": ("<", True),
        b"\xfe\xed\xfa\xce": (">", False),
        b"\xfe\xed\xfa\xcf": (">", True),
    }
    if magic not in thin_formats:
        fail("executable slice is not a supported Mach-O")
    endian, is_64 = thin_formats[magic]
    header_size = 32 if is_64 else 28
    if len(payload) < header_size:
        fail("Mach-O header is truncated")
    cpu_type = unpack_u32(payload, 4, endian)
    cpu_subtype = unpack_u32(payload, 8, endian)
    command_count = unpack_u32(payload, 16, endian)
    command_bytes = unpack_u32(payload, 20, endian)
    command_end = header_size + command_bytes
    if command_end > len(payload) or command_count > 16_384:
        fail("Mach-O load-command table is invalid")

    cursor = header_size
    signature_commands: list[tuple[int, int, int]] = []
    linkedit_fields: list[tuple[int, int]] = []
    for _ in range(command_count):
        if cursor + 8 > command_end:
            fail("Mach-O load-command table is truncated")
        command = unpack_u32(payload, cursor, endian)
        command_size = unpack_u32(payload, cursor + 4, endian)
        if command_size < 8 or cursor + command_size > command_end:
            fail("Mach-O load command has an invalid size")
        if command == LC_CODE_SIGNATURE:
            if command_size != 16:
                fail("LC_CODE_SIGNATURE has an invalid size")
            signature_commands.append(
                (
                    cursor,
                    unpack_u32(payload, cursor + 8, endian),
                    unpack_u32(payload, cursor + 12, endian),
                )
            )
        elif command in {LC_SEGMENT, LC_SEGMENT_64}:
            expected_minimum = 72 if command == LC_SEGMENT_64 else 56
            if command_size < expected_minimum:
                fail("Mach-O segment command is truncated")
            segment_name = payload[cursor + 8 : cursor + 24].split(b"\0", 1)[0]
            if segment_name == b"__LINKEDIT":
                if command == LC_SEGMENT_64:
                    linkedit_fields.append((cursor + 32, 8))  # vmsize
                    linkedit_fields.append((cursor + 48, 8))  # filesize
                else:
                    linkedit_fields.append((cursor + 28, 4))
                    linkedit_fields.append((cursor + 36, 4))
        cursor += command_size
    if cursor != command_end:
        fail("Mach-O load-command count/size mismatch")
    if len(signature_commands) != 1:
        fail("Mach-O slice must contain exactly one LC_CODE_SIGNATURE")
    signature_command, signature_offset, signature_size = signature_commands[0]
    if (
        signature_offset < command_end
        or signature_size <= 0
        or signature_offset + signature_size > len(payload)
    ):
        fail("Mach-O code-signature range is invalid")
    trailing = payload[signature_offset + signature_size :]
    if any(trailing):
        fail("Mach-O contains non-zero payload after its code signature")

    normalized = bytearray(payload[:signature_offset])
    normalized[signature_command + 8 : signature_command + 16] = b"\0" * 8
    for field_offset, field_size in linkedit_fields:
        normalized[field_offset : field_offset + field_size] = b"\0" * field_size
    return cpu_type, cpu_subtype, hashlib.sha256(normalized).digest()


def normalized_slices(payload: bytes) -> list[tuple[int, int, bytes]]:
    magic = payload[:4]
    fat_formats = {
        b"\xca\xfe\xba\xbe": (">", False),
        b"\xca\xfe\xba\xbf": (">", True),
        b"\xbe\xba\xfe\xca": ("<", False),
        b"\xbf\xba\xfe\xca": ("<", True),
    }
    if magic not in fat_formats:
        return [normalized_thin_slice(payload)]
    endian, is_64 = fat_formats[magic]
    architecture_count = unpack_u32(payload, 4, endian)
    entry_size = 32 if is_64 else 20
    table_end = 8 + architecture_count * entry_size
    if architecture_count == 0 or architecture_count > 64 or table_end > len(payload):
        fail("universal Mach-O architecture table is invalid")
    slices: list[tuple[int, int, bytes]] = []
    ranges: list[tuple[int, int]] = []
    for index in range(architecture_count):
        cursor = 8 + index * entry_size
        cpu_type = unpack_u32(payload, cursor, endian)
        cpu_subtype = unpack_u32(payload, cursor + 4, endian)
        if is_64:
            try:
                offset, size = struct.unpack_from(endian + "QQ", payload, cursor + 8)
            except struct.error:
                fail("universal Mach-O 64-bit architecture entry is truncated")
        else:
            offset = unpack_u32(payload, cursor + 8, endian)
            size = unpack_u32(payload, cursor + 12, endian)
        if offset < table_end or size == 0 or offset + size > len(payload):
            fail("universal Mach-O slice range is invalid")
        for previous_start, previous_end in ranges:
            if offset < previous_end and previous_start < offset + size:
                fail("universal Mach-O slices overlap")
        ranges.append((offset, offset + size))
        actual_type, actual_subtype, digest = normalized_thin_slice(payload[offset : offset + size])
        if (cpu_type, cpu_subtype) != (actual_type, actual_subtype):
            fail("universal Mach-O table architecture differs from its slice header")
        slices.append((cpu_type, cpu_subtype, digest))
    return slices


def normalized_digest(path: Path) -> str:
    payload, mode = stable_regular_file(path)
    if mode & 0o111 == 0:
        fail(f"Mach-O executable has no executable permission bit: {path}")
    slices = normalized_slices(payload)
    digest = hashlib.sha256()
    digest.update(DOMAIN)
    digest.update(len(slices).to_bytes(4, "big"))
    for cpu_type, cpu_subtype, slice_digest in slices:
        digest.update(struct.pack(">II", cpu_type, cpu_subtype))
        digest.update(slice_digest)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    print(normalized_digest(args.executable))


if __name__ == "__main__":
    main()
