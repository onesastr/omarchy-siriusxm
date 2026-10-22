"""End-to-end check of the proxy + mpv chain against a fake, encrypted upstream.

Builds an AES-128 HLS stream with ffmpeg, serves it as a live sliding window,
fakes the SiriusXM API (lineup/tune/key/liveUpdate), then runs the real daemon
and drives it through the CLI client. Needs ffmpeg and mpv; plays to --ao=null.

    python3 tests/e2e_fake_upstream.py
"""

import base64
import http.server
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUID = "0f3c9b2e-1a2b-4c5d-8e9f-0123456789ab"
KEY = bytes(range(16))


def build_stream(directory):
    with open(os.path.join(directory, "enc.key"), "wb") as handle:
        handle.write(KEY)
    with open(os.path.join(directory, "keyinfo"), "w") as handle:
        handle.write(f"https://api.example/playback/key/v1/{GUID}\n{directory}/enc.key\n")
    subprocess.run([
        "ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=60",
        "-c:a", "aac", "-b:a", "64k", "-f", "hls", "-hls_time", "4", "-hls_list_size", "0",
        "-hls_key_info_file", os.path.join(directory, "keyinfo"),
        "-hls_segment_filename", os.path.join(directory, "seg_%03d.ts"),
        os.path.join(directory, "full.m3u8"),
    ], check=True)
    lines = open(os.path.join(directory, "full.m3u8")).read().splitlines()
    key_line = next(l for l in lines if l.startswith("#EXT-X-KEY"))
    segments = [(lines[i], lines[i + 1]) for i, l in enumerate(lines) if l.startswith("#EXTINF")]
    return key_line, segments


def serve_upstream(directory, key_line, segments, started):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path.startswith("/master.m3u8"):
                body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=70000\nlive/variant.m3u8\n"
            elif self.path.startswith("/live/variant.m3u8"):
                # sliding window of 3 segments that advances in real time
                index = min(int((time.time() - started) / 4), len(segments) - 3)
                pdt = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(started + index * 4))
                out = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:4",
                       f"#EXT-X-MEDIA-SEQUENCE:{index}", key_line,
                       f"#EXT-X-PROGRAM-DATE-TIME:{pdt}.000+00:00Z"]
                for extinf, name in segments[index:index + 3]:
                    out += [extinf, "../" + name]
                body = "\n".join(out) + "\n"
            else:
                return super().do_GET()
            data = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


class FakeApi:
    def __init__(self, port, started):
        self.port = port
        self.started = started
        self.key_calls = 0

    def reset(self, keep_device=True):
        pass

    def login(self):
        pass

    def lineup(self):
        return {"container": {"sets": [{"items": [
            {"entity": {"id": f"chan-{n}", "type": "channel-linear",
                        "texts": {"title": {"default": f"Test {n}"}}},
             "decorations": {"channelNumber": n, "genre": "Test"}} for n in (1, 2, 3)]}]}}

    def tune(self, channel_id, entity_type):
        return {"streams": [{"urls": [{"url": f"http://127.0.0.1:{self.port}/master.m3u8?token=x",
                                       "isPrimary": True}]}]}

    def key(self, guid):
        assert guid == GUID, guid
        self.key_calls += 1
        return KEY

    def live_update(self, channel_id):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(self.started - 5))
        return {"items": [{"name": "Sine Wave", "artistName": "Test Tone", "timestamp": stamp,
                           "duration": 120000}]}


def main():
    with tempfile.TemporaryDirectory() as tmp:
        runtime = os.path.join(tmp, "runtime")
        for var, sub in (("XDG_RUNTIME_DIR", "runtime"), ("XDG_STATE_HOME", "state"),
                         ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")):
            os.environ[var] = os.path.join(tmp, sub)
            os.makedirs(os.environ[var])
        loader = importlib.machinery.SourceFileLoader("sxm", os.path.join(ROOT, "sxm"))
        spec = importlib.util.spec_from_loader("sxm", loader)
        sxm = importlib.util.module_from_spec(spec)
        loader.exec_module(sxm)

        media = os.path.join(tmp, "media")
        os.makedirs(media)
        key_line, segments = build_stream(media)
        started = time.time()
        port = serve_upstream(media, key_line, segments, started)

        daemon = sxm.Daemon()
        daemon.api = FakeApi(port, started)
        daemon.logged_in = True
        sxm.Keyring.load = staticmethod(lambda: {"username": "t", "password": "t"})
        os.environ["SXM_MPV_ARGS"] = "--ao=null"
        threading.Thread(target=daemon.serve, daemon=True).start()
        for _ in range(100):
            if sxm.daemon_info():
                break
            time.sleep(0.05)
        info = sxm.daemon_info()
        assert info, "daemon did not start"

        failures = []

        def check(label, condition):
            print(("PASS " if condition else "FAIL ") + label)
            if not condition:
                failures.append(label)

        channels = sxm.send(info, {"cmd": "channels"})["channels"]
        check("lineup has 3 channels", len(channels) == 3)
        sxm.send(info, {"cmd": "play", "id": "2"})
        deadline = time.time() + 20
        status = {}
        while time.time() < deadline:
            status = read(os.path.join(runtime, sxm.APP, "status.json"))
            if status.get("state") == "playing" and (status.get("track") or {}).get("title"):
                break
            time.sleep(0.5)
        check(f"plays and decrypts (state={status.get('state')} error={status.get('error')!r})",
              status.get("state") == "playing")
        check("key fetched through proxy", daemon.api.key_calls >= 1)
        check("now playing resolved", (status.get("track") or {}).get("title") == "Sine Wave")
        check("channel is Test 2", (status.get("channel") or {}).get("name") == "Test 2")
        time.sleep(6)
        position = daemon.mpv.command("get_property", "playback-time")
        check(f"playback advancing past 4s (t={position})", isinstance(position, (int, float)) and position > 4)
        title = daemon.mpv.command("get_property", "media-title")
        check(f"mpv media-title set ({title!r})", title == "Test Tone — Sine Wave")

        sxm.send(info, {"cmd": "next"})
        time.sleep(3)
        status = read(os.path.join(runtime, sxm.APP, "status.json"))
        check("next switches to Test 3", (status.get("channel") or {}).get("name") == "Test 3")

        sxm.send(info, {"cmd": "toggle"})
        time.sleep(0.5)
        check("toggle pauses", read(os.path.join(runtime, sxm.APP, "status.json")).get("state") == "paused")
        check("volume -5", sxm.send(info, {"cmd": "volume", "value": "-5"})["volume"] == sxm.DEFAULT_VOLUME - 5)
        sxm.send(info, {"cmd": "stop"})
        time.sleep(0.5)
        check("stop quits mpv", not daemon.mpv.alive())
        daemon.shutdown.set()
        time.sleep(0.5)
        print("ALL PASSED" if not failures else f"{len(failures)} FAILED")
        return 1 if failures else 0


def read(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return {}


if __name__ == "__main__":
    sys.exit(main())
