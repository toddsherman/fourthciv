#!/usr/bin/env python3
"""Real processes and TCP: signed posting, replication, restart, rejection, and pause."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
import argparse
import ipaddress

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / ".build/debug/fourthciv"
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
LAN_ARGS = []


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def api(base, path="/v1/events", body=None, headers=None):
    request = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with HTTP.open(request, timeout=3) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def cli(*args):
    result = subprocess.run([str(CLI), *map(str, args), *LAN_ARGS], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def eventually(check, seconds=18):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.15)
    raise AssertionError("Condition did not become true")


def main():
    global LAN_ARGS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lan-host', help='This Mac’s private IPv4 address; enables trusted-LAN test listeners')
    args = parser.parse_args()
    host = args.lan_host or '127.0.0.1'
    if args.lan_host:
        address = ipaddress.IPv4Address(host)
        assert any(address in ipaddress.IPv4Network(network) for network in ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16'])
        LAN_ARGS = ['--lan', 'true']
    processes = []
    with tempfile.TemporaryDirectory(prefix="fourthciv-integration-") as temp:
        temp = Path(temp)
        ports = [free_port(), free_port()]
        while ports[0] == ports[1]:
            ports[1] = free_port()
        bases = [f"http://{host}:{port}" for port in ports]

        def start(index):
            process = subprocess.Popen([str(CLI), "serve", "--data", str(temp / f"node{index}"),
                                        "--port", str(ports[index]), "--peer", bases[1-index], *LAN_ARGS],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            processes.append(process)
            eventually(lambda: api(bases[index], "/v1/health")[0] == 200, seconds=5)
            return process

        try:
            a, b = start(0), start(1)
            identity_a, identity_b = temp / "a.identity.json", temp / "b.identity.json"
            cli("identity", "--out", identity_a, "--name", "Integration A", "--provider", "Self-reported test provider")
            cli("identity", "--out", identity_b, "--name", "Integration B")
            assert os.stat(identity_a).st_mode & 0o777 == 0o600
            town = cli("community", "--identity", identity_a, "--node", bases[0], "--title", "Test town", "--body", "Public integration test")
            first = cli("post", "--identity", identity_a, "--node", bases[0], "--community", town["id"], "--body", "Can another node hear this?")
            eventually(lambda: len(api(bases[1])[1]["events"]) == 2)
            reply = cli("post", "--identity", identity_b, "--node", bases[1], "--community", town["id"], "--reply", first["id"], "--body", "Yes, across a real TCP connection.")
            eventually(lambda: len(api(bases[0])[1]["events"]) == 3)
            original = api(bases[0])[1]["events"]
            assert api(bases[0], "/v1/communities")[1]["events"] == [original[0]]
            assert cli("communities", "--node", bases[0]) == [original[0]]
            assert len({event["author"] for event in original}) == 2
            assert api(bases[0], body=original[0])[1]["result"] == "already-present"
            tampered = {**original[1], "body": "A forged replacement"}
            assert api(bases[0], body=tampered)[0] == 400
            assert api(bases[0], body=original[0], headers={"Origin": "https://example.com"})[0] == 403
            assert api(bases[0], headers={"Host": "evil.test"})[0] == 403
            assert len(api(bases[0])[1]["events"]) == 3
            assert api(bases[1], "/.well-known/fourthciv")[1]["visibility"] == "public"
            print("PASS: two signed identities, two-way replication, reply references, replay deduplication, forged-event and browser-origin rejection", flush=True)

            a.terminate(); a.wait(timeout=5)
            assert len(api(bases[1])[1]["events"]) == 3
            b.terminate(); b.wait(timeout=5)
            b = start(1)
            assert api(bases[1])[1]["events"] == original
            print("PASS: replicated conversation survives origin shutdown and replica restart", flush=True)

            b.terminate(); b.wait(timeout=5)
            config = temp / "node1/settings.json"
            settings = json.loads(config.read_text()); settings["paused"] = True
            config.write_text(json.dumps(settings))
            b = start(1)
            assert api(bases[1], "/v1/health")[1]["status"] == "Paused"
            assert api(bases[1], body=original[0])[0] == 503
            assert len(api(bases[1])[1]["events"]) == 3
            a = start(0)
            cli("post", "--identity", identity_a, "--node", bases[0], "--community", town["id"], "--body", "Must not arrive at the paused node")
            time.sleep(11)
            assert len(api(bases[1])[1]["events"]) == 3
            print("PASS: pause persists, rejects writes, stops synchronization, and retains local reading", flush=True)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
    print(f"All integration checks passed via {host}; temporary nodes and identities removed.")


if __name__ == "__main__":
    main()
