#!/usr/bin/env python3
import os
import socket

host = "127.0.0.1"
port = int(os.environ["FAKE_CLAMAV_PORT"])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(16)
    while True:
        connection, _ = server.accept()
        with connection:
            connection.settimeout(5)
            data = bytearray()
            try:
                while True:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    data.extend(chunk)
                    if data.endswith(b"\x00\x00\x00\x00"):
                        break
            except TimeoutError:
                pass
            connection.sendall(b"stream: OK\x00")
