#!/usr/bin/env python3
"""Minimal PostgreSQL v3 protocol probe used by the WASIX smoke test."""

import argparse
import socket
import struct
import sys


def packet(kind: bytes, payload: bytes) -> bytes:
    return kind + struct.pack("!I", len(payload) + 4) + payload


def read_exact(sock: socket.socket, length: int) -> bytes:
    data = bytearray()
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise RuntimeError("PostgreSQL closed the connection")
        data.extend(chunk)
    return bytes(data)


def read_message(sock: socket.socket) -> tuple[bytes, bytes]:
    kind = read_exact(sock, 1)
    length = struct.unpack("!I", read_exact(sock, 4))[0]
    if length < 4:
        raise RuntimeError(f"invalid PostgreSQL message length: {length}")
    return kind, read_exact(sock, length - 4)


def error_text(payload: bytes) -> str:
    fields = []
    for field in payload.rstrip(b"\0").split(b"\0"):
        if len(field) > 1:
            fields.append(field[1:].decode("utf-8", "replace"))
    return ": ".join(fields) or "unknown PostgreSQL error"


def wait_ready(sock: socket.socket) -> None:
    while True:
        kind, payload = read_message(sock)
        if kind == b"E":
            raise RuntimeError(error_text(payload))
        if kind == b"Z":
            return


def query(sock: socket.socket, sql: str) -> list[list[str | None]]:
    sock.sendall(packet(b"Q", sql.encode() + b"\0"))
    rows = []
    while True:
        kind, payload = read_message(sock)
        if kind == b"E":
            raise RuntimeError(error_text(payload))
        if kind == b"D":
            count = struct.unpack_from("!H", payload)[0]
            offset = 2
            row = []
            for _ in range(count):
                length = struct.unpack_from("!i", payload, offset)[0]
                offset += 4
                if length < 0:
                    row.append(None)
                else:
                    row.append(payload[offset : offset + length].decode())
                    offset += length
            rows.append(row)
        if kind == b"Z":
            return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5432)
    parser.add_argument("--database", default="postgres")
    parser.add_argument("sql", nargs="+")
    args = parser.parse_args()

    with socket.create_connection((args.host, args.port), timeout=2) as sock:
        startup = (
            b"user\0postgres\0database\0"
            + args.database.encode()
            + b"\0client_encoding\0UTF8\0\0"
        )
        sock.sendall(struct.pack("!II", len(startup) + 8, 196608) + startup)
        wait_ready(sock)
        for statement in args.sql:
            for row in query(sock, statement):
                print("\t".join("" if value is None else value for value in row))
        sock.sendall(packet(b"X", b""))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
