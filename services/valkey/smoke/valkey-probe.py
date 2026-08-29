#!/usr/bin/env python3
"""Small dependency-free RESP client for the Valkey/WASIX smoke test."""

import argparse
import json
import socket
import sys


def read_exact(stream, length):
    chunks = []
    remaining = length
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise RuntimeError("server closed the connection")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_line(stream):
    line = stream.readline()
    if not line.endswith(b"\r\n"):
        raise RuntimeError("invalid RESP line")
    return line[:-2]


def read_response(stream):
    prefix = read_exact(stream, 1)
    if prefix == b"+":
        return read_line(stream).decode(errors="replace")
    if prefix == b"-":
        raise RuntimeError(read_line(stream).decode(errors="replace"))
    if prefix == b":":
        return int(read_line(stream))
    if prefix == b"$":
        length = int(read_line(stream))
        if length == -1:
            return None
        value = read_exact(stream, length)
        if read_exact(stream, 2) != b"\r\n":
            raise RuntimeError("invalid RESP bulk string")
        return value.decode(errors="replace")
    if prefix == b"*":
        length = int(read_line(stream))
        if length == -1:
            return None
        return [read_response(stream) for _ in range(length)]
    if prefix == b"_":
        read_line(stream)
        return None
    if prefix == b"#":
        return read_line(stream) == b"t"
    if prefix == b"%":
        length = int(read_line(stream))
        return {str(read_response(stream)): read_response(stream) for _ in range(length)}
    raise RuntimeError(f"unsupported RESP type: {prefix!r}")


def encode_command(arguments):
    encoded = [str(argument).encode() for argument in arguments]
    pieces = [f"*{len(encoded)}\r\n".encode()]
    for argument in encoded:
        pieces.extend((f"${len(argument)}\r\n".encode(), argument, b"\r\n"))
    return b"".join(pieces)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6380)
    parser.add_argument("command", nargs="+")
    args = parser.parse_args()

    with socket.create_connection((args.host, args.port), timeout=10) as sock:
        sock.sendall(encode_command(args.command))
        with sock.makefile("rb") as stream:
            try:
                response = read_response(stream)
            except RuntimeError as exc:
                if args.command[0].upper() == "SHUTDOWN" and str(exc) == "server closed the connection":
                    response = "OK"
                else:
                    raise

    if isinstance(response, (list, dict, bool)):
        print(json.dumps(response, separators=(",", ":"), sort_keys=True))
    elif response is None:
        print("(nil)")
    else:
        print(response)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(exc, file=sys.stderr)
        raise SystemExit(1)
