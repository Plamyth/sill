#!/usr/bin/env python3
"""Bridge newline JSON-RPC on stdio to Codex's Unix WebSocket transport."""

import asyncio
import sys

from websockets.asyncio.client import unix_connect


async def main(socket_path: str) -> None:
    async with unix_connect(socket_path, uri="ws://localhost", max_size=4 * 1024 * 1024) as socket:
        async def send() -> None:
            while line := await asyncio.to_thread(sys.stdin.buffer.readline):
                await socket.send(line.decode("utf-8").rstrip("\n"))

        async def receive() -> None:
            async for message in socket:
                if not isinstance(message, str):
                    continue
                sys.stdout.write(message + "\n")
                sys.stdout.flush()

        sender = asyncio.create_task(send())
        receiver = asyncio.create_task(receive())
        done, pending = await asyncio.wait((sender, receiver), return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        for task in done:
            task.result()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(2)
    asyncio.run(main(sys.argv[1]))
