"""Tests for the Nasdaq BinaryFILE capture reader (model/binaryfile.py)."""

import gzip
import struct

from model.binaryfile import read_messages


def _record(payload: bytes) -> bytes:
    return struct.pack('>H', len(payload)) + payload


def test_read_messages_plain(tmp_path):
    payloads = [b'AAAA', b'BB', b'CCCCCCCC']
    path = tmp_path / "capture.bin"
    path.write_bytes(b''.join(_record(p) for p in payloads))

    assert list(read_messages(str(path))) == payloads


def test_read_messages_gz(tmp_path):
    payloads = [b'AAAA', b'BB', b'CCCCCCCC']
    path = tmp_path / "capture.bin.gz"
    with gzip.open(path, 'wb') as f:
        f.write(b''.join(_record(p) for p in payloads))

    assert list(read_messages(str(path))) == payloads


def test_read_messages_limit(tmp_path):
    payloads = [b'AAAA', b'BB', b'CCCCCCCC']
    path = tmp_path / "capture.bin"
    path.write_bytes(b''.join(_record(p) for p in payloads))

    assert list(read_messages(str(path), limit=2)) == payloads[:2]


def test_read_messages_empty_file(tmp_path):
    path = tmp_path / "empty.bin"
    path.write_bytes(b'')

    assert list(read_messages(str(path))) == []
