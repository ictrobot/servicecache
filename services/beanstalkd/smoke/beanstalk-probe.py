#!/usr/bin/env python3
import argparse
from contextlib import ExitStack
import os
import socket
import time


def read_line(stream):
    data = stream.readline()
    if not data:
        raise RuntimeError("server closed the connection")
    if not data.endswith(b"\r\n"):
        raise RuntimeError(f"malformed response: {data!r}")
    return data[:-2]


def expect_prefix(stream, prefix):
    response = read_line(stream)
    if not response.startswith(prefix):
        raise RuntimeError(f"expected {prefix!r}, received {response!r}")
    print(response.decode("ascii"))
    return response


def main():
    parser = argparse.ArgumentParser(description="exercise a beanstalkd TCP server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=11300)
    parser.add_argument("--tube")
    parser.add_argument("--fanout", type=int, default=16)
    args = parser.parse_args()
    tube = args.tube or f"wasix-smoke-{os.getpid()}"

    body = b"hello wasix"
    with ExitStack() as stack:
        def connect():
            deadline = time.monotonic() + 10
            while True:
                try:
                    connection = socket.create_connection(
                        (args.host, args.port), timeout=5
                    )
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.1)
            connection = stack.enter_context(connection)
            return stack.enter_context(connection.makefile("rwb", buffering=0))

        producer = connect()
        worker = connect()
        inspector = connect()

        worker.write(f"watch {tube}\r\n".encode("ascii"))
        expect_prefix(worker, b"WATCHING ")
        worker.write(b"ignore default\r\n")
        expect_prefix(worker, b"WATCHING 1")
        worker.write(b"reserve-with-timeout 1\r\n")

        producer.write(f"use {tube}\r\n".encode("ascii"))
        expect_prefix(producer, b"USING ")
        producer.write(f"put 0 0 60 {len(body)}\r\n".encode("ascii") + body + b"\r\n")
        inserted = expect_prefix(producer, b"INSERTED ")
        job_id = inserted.split()[1]

        reserved = expect_prefix(worker, b"RESERVED ")
        reserved_id, body_size = reserved.split()[1:]
        if reserved_id != job_id:
            raise RuntimeError("reserved a different job than the one inserted")
        reserved_body = worker.read(int(body_size) + 2)
        if reserved_body != body + b"\r\n":
            raise RuntimeError(f"job body mismatch: {reserved_body!r}")
        print(reserved_body[:-2].decode("ascii"))

        worker.write(b"delete " + job_id + b"\r\n")
        expect_prefix(worker, b"DELETED")

        inspector.write(f"stats-tube {tube}\r\n".encode("ascii"))
        header = expect_prefix(inspector, b"OK ")
        stats = inspector.read(int(header.split()[1]) + 2)
        if b"total-jobs: 1\n" not in stats or b"current-jobs-ready: 0\n" not in stats:
            raise RuntimeError(f"unexpected tube stats: {stats!r}")
        print("tube stats: total-jobs=1, current-jobs-ready=0")

        fanout = [connect() for _ in range(args.fanout)]
        for index, stream in enumerate(fanout):
            stream.write(f"use wasix-fanout-{os.getpid()}-{index}\r\n".encode("ascii"))
        for stream in fanout:
            expect_prefix(stream, b"USING ")

        expected_connections = 3 + args.fanout
        inspector.write(b"stats\r\n")
        header = expect_prefix(inspector, b"OK ")
        stats = inspector.read(int(header.split()[1]) + 2)
        expected_stat = f"current-connections: {expected_connections}\n".encode("ascii")
        if expected_stat not in stats:
            raise RuntimeError(f"expected {expected_stat!r} in server stats: {stats!r}")
        print(f"simultaneous connections: {expected_connections}")


if __name__ == "__main__":
    main()
