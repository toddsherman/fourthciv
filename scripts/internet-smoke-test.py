#!/usr/bin/env python3
"""Publish four labeled test events through two local nodes and a live HTTPS relay."""
import argparse
import json
from pathlib import Path
import selectors
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / ".build/debug/fourthciv"
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def api(base, path="/v1/events", body=None, headers=None):
    request = urllib.request.Request(base + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with HTTP.open(request, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def cli(*args):
    result = subprocess.run([str(CLI), *map(str, args)], check=True,
        capture_output=True, text=True, timeout=20)
    return json.loads(result.stdout)


def eventually(check, seconds=120, interval=2):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(interval)
    raise AssertionError("Condition did not become true before the timeout")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def contains(base, event_id):
    offset = 0
    for _ in range(2001):
        status, page = api(base, f"/v1/events?offset={offset}")
        if status != 200:
            return False
        if any(event["id"] == event_id for event in page["events"]):
            return True
        following = page.get("next")
        if following is None:
            return False
        assert offset < following <= 2000, "Invalid relay pagination"
        offset = following
    raise AssertionError("Pagination did not complete")


def read_ledger(file):
    ledger = json.loads(file.read_text())
    # Swift serializes a Set as a JSON array whose order can change on restart.
    for progress in ledger["relays"].values():
        progress["acknowledged"] = sorted(progress["acknowledged"])
    return ledger


def main():
    parser = argparse.ArgumentParser(description=__doc__ + " Events remain publicly stored.")
    parser.add_argument("--relay", required=True, help="HTTPS relay to test; publishes public test events")
    args = parser.parse_args()
    relay = args.relay.rstrip("/")
    url = urllib.parse.urlparse(relay)
    if url.scheme != "https" or not url.hostname or url.path or url.query or url.fragment or url.username or url.password or url.port:
        parser.error("Use an HTTPS relay hostname without a path, credentials, or port")
    discovery = cli("discover", "--node", relay, "--internet", "true")
    assert discovery["protocol"] == "fourthciv/1"
    assert discovery["visibility"] == "public" and "relay-sync-v1" in discovery["capabilities"]
    print("PASS: compatible public discovery over platform-verified HTTPS", flush=True)

    processes = []
    with tempfile.TemporaryDirectory(prefix="fourthciv-internet-smoke-") as temporary:
        directory = Path(temporary)
        ports = [free_port(), free_port()]
        while ports[0] == ports[1]:
            ports[1] = free_port()
        bases = [f"http://127.0.0.1:{port}" for port in ports]

        def start(index):
            process = subprocess.Popen([str(CLI), "serve", "--data", str(directory / f"node{index}"),
                "--port", str(ports[index]), "--lan", "false", "--internet", "true", "--relay", relay],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            processes.append(process)
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                assert selector.select(timeout=10), "Node startup timed out"
            assert process.stdout.readline(), "Node did not start"
            assert api(bases[index], "/v1/health")[0] == 200
            return process

        def stop(process):
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

        def pause(index, value):
            file = directory / f"node{index}" / "settings.json"
            settings = json.loads(file.read_text())
            assert not settings["lanEnabled"] and not settings["peers"]
            settings["paused"] = value
            file.write_text(json.dumps(settings))

        try:
            a, b = start(0), start(1)
            key_a, key_b = directory / "a.identity.json", directory / "b.identity.json"
            for key, name in [(key_a, "Pilot test A"), (key_b, "Pilot test B")]:
                cli("identity", "--out", key, "--name", name, "--runtime", "Fourth Civ deployment smoke test",
                    "--project", "Labeled infrastructure verification; not autonomous agent activity")
            community = cli("community", "--identity", key_a, "--node", bases[0],
                "--title", "Internet pilot verification " + time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime()),
                "--body", "Public infrastructure test using two isolated node processes on one Mac and the hosted HTTPS relay. This is not a two-physical-Mac test or an autonomous conversation.")
            message = cli("post", "--identity", key_a, "--node", bases[0], "--community", community["id"],
                "--body", "Test A: this signed message should reach node B through the HTTPS relay.")
            eventually(lambda: contains(bases[1], message["id"]))
            reply = cli("post", "--identity", key_b, "--node", bases[1], "--community", community["id"],
                "--reply", message["id"], "--body", "Test B: received and verified. Returning this signed reply through the relay.")
            eventually(lambda: contains(bases[0], reply["id"]))
            print("PASS: two signing identities exchanged a message and reply through the hosted relay; LAN and direct peers disabled", flush=True)

            hosted = cli("events", "--node", relay, "--internet", "true")
            original = next(event for event in hosted if event["id"] == message["id"])
            assert api(relay, body=original)[1]["result"] == "already-present"
            assert api(relay, body={**original, "body": "Tampered verification message"})[0] == 400
            assert api(relay, body=original, headers={"Origin": "https://example.com"})[0] == 403
            print("PASS: Swift verified hosted signatures; relay deduplicates replay and rejects tampering and browser-origin writes", flush=True)

            stop(b)
            pause(1, True)
            b = start(1)
            assert api(bases[1], "/v1/health")[1]["status"] == "Paused"
            later = cli("post", "--identity", key_a, "--node", bases[0], "--community", community["id"],
                "--body", "Test A: pause/resume verification. Node B should receive this only after resuming.")
            eventually(lambda: contains(relay, later["id"]), interval=5)
            time.sleep(40)
            assert not contains(bases[1], later["id"])
            stop(b)
            pause(1, False)
            b = start(1)
            eventually(lambda: contains(bases[1], later["id"]))
            print("PASS: pause blocks hosted synchronization; restart and resume catch up", flush=True)

            stop(a)
            stop(b)
            ledger_file = directory / "node1/internet-sync.json"
            ledger = read_ledger(ledger_file)
            pause(1, True)
            b = start(1)
            retained = cli("events", "--node", bases[1])
            expected = {community["id"], message["id"], reply["id"], later["id"]}
            assert expected <= {event["id"] for event in retained}
            assert len(retained) == len({event["id"] for event in retained})
            assert read_ledger(ledger_file) == ledger, "Sync progress or accounting changed while paused"
            print("PASS: verified history and sync ledger survive restart with origin offline and synchronization paused", flush=True)
            print(json.dumps({"relay": relay, "community": community["id"], "publicTestEvents": 4,
                "physicalMacs": 1, "result": "passed"}), flush=True)
        finally:
            for process in processes:
                if process.poll() is None:
                    stop(process)
    print("Local test processes, signing keys, and stores removed. Labeled public test events remain on the relay.", flush=True)


if __name__ == "__main__":
    main()
