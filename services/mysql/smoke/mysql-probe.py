#!/usr/bin/env python3
"""Minimal dependency-free MySQL protocol client for the WASIX smoke test."""

import argparse
import socket
import struct
import sys


CLIENT_LONG_PASSWORD = 0x00000001
CLIENT_LONG_FLAG = 0x00000004
CLIENT_PROTOCOL_41 = 0x00000200
CLIENT_TRANSACTIONS = 0x00002000
CLIENT_SECURE_CONNECTION = 0x00008000
CLIENT_PLUGIN_AUTH = 0x00080000


def read_exact(sock, length):
    chunks = []
    while length:
        chunk = sock.recv(length)
        if not chunk:
            raise RuntimeError("server closed the connection")
        chunks.append(chunk)
        length -= len(chunk)
    return b"".join(chunks)


def read_packet(sock):
    header = read_exact(sock, 4)
    length = int.from_bytes(header[:3], "little")
    return header[3], read_exact(sock, length)


def write_packet(sock, sequence, payload):
    sock.sendall(len(payload).to_bytes(3, "little") + bytes([sequence]) + payload)


def read_lenenc(data, offset=0):
    first = data[offset]
    if first < 0xFB:
        return first, offset + 1
    if first == 0xFC:
        return int.from_bytes(data[offset + 1 : offset + 3], "little"), offset + 3
    if first == 0xFD:
        return int.from_bytes(data[offset + 1 : offset + 4], "little"), offset + 4
    if first == 0xFE:
        return int.from_bytes(data[offset + 1 : offset + 9], "little"), offset + 9
    if first == 0xFB:
        return None, offset + 1
    raise RuntimeError("invalid length-encoded value")


def error_message(payload):
    code = int.from_bytes(payload[1:3], "little")
    message_offset = 9 if len(payload) >= 9 and payload[3:4] == b"#" else 3
    return f"MySQL error {code}: {payload[message_offset:].decode(errors='replace')}"


def connect(host, port, user):
    sock = socket.create_connection((host, port), timeout=10)
    _, handshake = read_packet(sock)
    if not handshake or handshake[0] == 0xFF:
        raise RuntimeError(error_message(handshake))

    version_end = handshake.index(0, 1)
    position = version_end + 1 + 4 + 8 + 1
    server_capabilities = int.from_bytes(handshake[position : position + 2], "little")
    position += 2
    if len(handshake) >= position + 13:
        position += 1 + 2
        server_capabilities |= (
            int.from_bytes(handshake[position : position + 2], "little") << 16
        )

    wanted = (
        CLIENT_LONG_PASSWORD
        | CLIENT_LONG_FLAG
        | CLIENT_PROTOCOL_41
        | CLIENT_TRANSACTIONS
        | CLIENT_SECURE_CONNECTION
        | CLIENT_PLUGIN_AUTH
    )
    capabilities = wanted & server_capabilities
    response = struct.pack("<IIB23x", capabilities, 16 * 1024 * 1024, 45)
    response += user.encode() + b"\0"
    response += b"\0"  # Empty auth response for --initialize-insecure.
    if capabilities & CLIENT_PLUGIN_AUTH:
        response += b"caching_sha2_password\0"
    write_packet(sock, 1, response)

    sequence, reply = read_packet(sock)
    if reply[0] == 0xFF:
        raise RuntimeError(error_message(reply))
    if reply[0] == 0xFE:
        # Auth switch request. The initialized root account has an empty password.
        write_packet(sock, sequence + 1, b"")
        _, reply = read_packet(sock)
    if reply[0] == 0x01 and reply[1:2] == b"\x03":
        _, reply = read_packet(sock)
    if reply[0] == 0xFF:
        raise RuntimeError(error_message(reply))
    if reply[0] != 0x00:
        raise RuntimeError(f"unexpected authentication response: {reply.hex()}")
    return sock


def query(sock, sql):
    write_packet(sock, 0, b"\x03" + sql.encode())
    _, first = read_packet(sock)
    if first[0] == 0xFF:
        raise RuntimeError(error_message(first))
    if first[0] == 0x00:
        return []

    column_count, _ = read_lenenc(first)
    columns = []
    for _ in range(column_count):
        _, packet = read_packet(sock)
        offset = 0
        fields = []
        for _ in range(6):
            length, offset = read_lenenc(packet, offset)
            fields.append(packet[offset : offset + length].decode(errors="replace"))
            offset += length
        columns.append(fields[4])

    _, terminator = read_packet(sock)
    if terminator[0] != 0xFE:
        raise RuntimeError("missing column terminator")

    rows = []
    while True:
        _, packet = read_packet(sock)
        if packet[0] == 0xFE and len(packet) < 9:
            break
        offset = 0
        row = []
        for _ in range(column_count):
            length, offset = read_lenenc(packet, offset)
            if length is None:
                row.append(None)
            else:
                row.append(packet[offset : offset + length].decode(errors="replace"))
                offset += length
        rows.append(row)
    return columns, rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3306)
    parser.add_argument("--user", default="root")
    parser.add_argument("query", nargs="+")
    args = parser.parse_args()

    sock = connect(args.host, args.port, args.user)
    try:
        for statement in args.query:
            result = query(sock, statement)
            print(f"> {statement}")
            if result:
                columns, rows = result
                print("\t".join(columns))
                for row in rows:
                    print("\t".join("NULL" if value is None else value for value in row))
            else:
                print("OK")
    finally:
        try:
            write_packet(sock, 0, b"\x01")
        finally:
            sock.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(exc, file=sys.stderr)
        raise SystemExit(1)
