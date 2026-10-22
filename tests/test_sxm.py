import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
loader = importlib.machinery.SourceFileLoader("sxm", os.path.join(ROOT, "sxm"))
spec = importlib.util.spec_from_loader("sxm", loader)
sxm = importlib.util.module_from_spec(spec)
loader.exec_module(sxm)

KEY_GUID = "0f3c9b2e-1a2b-4c5d-8e9f-0123456789ab"
MEDIA = f"""#EXTM3U
#EXT-X-VERSION:3
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:100
#EXT-X-KEY:METHOD=AES-128,URI="https://api.example/playback/key/v1/{KEY_GUID}",IV=0x01
#EXT-X-PROGRAM-DATE-TIME:2026-10-22T12:00:00.000+00:00Z
#EXTINF:10.0,
AAC_Data/seg_100.aac
#EXTINF:10.0,
AAC_Data/seg_101.aac
#EXT-X-ENDLIST
"""


class RewriteTests(unittest.TestCase):
    def setUp(self):
        self.base = "https://cdn.example/v1/chan/sec-1/256k/variant.m3u8?token=abc"
        self.text, self.segments = sxm.rewrite_playlist(MEDIA, self.base, "http://127.0.0.1:1/t")

    def test_key_points_at_proxy_and_keeps_iv(self):
        key_line = next(l for l in self.text.splitlines() if l.startswith("#EXT-X-KEY"))
        self.assertIn(f'URI="http://127.0.0.1:1/t/key/{KEY_GUID}"', key_line)
        self.assertIn("IV=0x01", key_line)

    def test_live_window(self):
        self.assertNotIn("#EXT-X-ENDLIST", self.text)
        self.assertNotIn("PLAYLIST-TYPE", self.text)

    def test_segments_are_proxied_and_absolute(self):
        lines = [l for l in self.text.splitlines() if not l.startswith("#")]
        self.assertEqual(len(lines), 2)
        target = urllib.parse.parse_qs(urllib.parse.urlsplit(lines[0]).query)["u"][0]
        self.assertEqual(target, "https://cdn.example/v1/chan/sec-1/256k/AAC_Data/seg_100.aac")
        self.assertIn(target, self.segments)

    def test_segment_end_times_follow_program_date_time(self):
        start = sxm.parse_time("2026-10-22T12:00:00Z")
        ends = sorted(self.segments.values())
        self.assertEqual(ends, [start + 10, start + 20])


class VariantTests(unittest.TestCase):
    def test_highest_bandwidth_regardless_of_order(self):
        master = "\n".join([
            "#EXTM3U",
            '#EXT-X-STREAM-INF:BANDWIDTH=281600,CODECS="mp4a.40.2"',
            "256k/x_256k_large_v3.m3u8",
            '#EXT-X-STREAM-INF:BANDWIDTH=70400,CODECS="mp4a.40.5"',
            "64k/x_64k_large_v3.m3u8",
        ])
        url = sxm.select_variant(master, "https://cdn.example/v1/x/master.m3u8?t=1")
        self.assertEqual(url, "https://cdn.example/v1/x/256k/x_256k_large_v3.m3u8")

    def test_media_playlist_passes_through(self):
        url = "https://cdn.example/a.m3u8"
        self.assertEqual(sxm.select_variant(MEDIA, url), url)


class LineupTests(unittest.TestCase):
    def test_normalize_sorts_and_flags_unentitled(self):
        raw = {"container": {"sets": [{"items": [
            {"entity": {"id": "b", "type": "channel-linear", "texts": {"title": {"default": "Hits 1"}},
                        "images": {"tile": {"aspect_1x1": {"preferredImage": {"url": "https://img/x.png"}}}}},
             "decorations": {"channelNumber": "2", "genre": "Pop"}},
            {"entity": {"id": "a", "texts": {"title": {"default": "Howard 100"}}},
             "decorations": {"channelNumber": 100}},
            {"entity": {"id": "c", "texts": {"title": {"default": "Locked"}}},
             "decorations": {"channelNumber": 5, "unentitled": True}},
        ]}]}}
        channels = sxm.normalize_lineup(raw)
        self.assertEqual([c["id"] for c in channels], ["b", "c", "a"])
        self.assertTrue(channels[1]["locked"])
        self.assertEqual(channels[0]["number"], 2)
        self.assertEqual(channels[0]["category"], "Pop")
        self.assertEqual(channels[0]["logo"], "https://img/x.png")
        self.assertEqual(channels[2]["type"], "channel-linear")

    def test_image_key_goes_through_image_server(self):
        url = sxm.image_url("abc/def.png", 300)
        self.assertTrue(url.startswith(sxm.IMG_BASE))
        params = json.loads(__import__("base64").b64decode(url[len(sxm.IMG_BASE):]))
        self.assertEqual(params["key"], "abc/def.png")


class CutTests(unittest.TestCase):
    items = [
        {"name": "Song A", "artistName": "X", "timestamp": "2026-10-22T12:00:00.000Z", "duration": 180000},
        {"name": "Song B", "artistName": "Y", "timestamp": "2026-10-22T12:03:00.000Z", "duration": 200000},
    ]

    def test_picks_cut_covering_position(self):
        position = sxm.parse_time("2026-10-22T12:04:00Z")
        self.assertEqual(sxm.current_cut(self.items, position)["name"], "Song B")

    def test_falls_back_to_latest_started(self):
        position = sxm.parse_time("2026-10-22T13:00:00Z")
        self.assertEqual(sxm.current_cut(self.items, position)["name"], "Song B")

    def test_empty(self):
        self.assertIsNone(sxm.current_cut([], 0))
        self.assertEqual(sxm.describe_cut(None)["title"], "")


class VolumeTests(unittest.TestCase):
    def test_level_matches_omarchy_linear_scale(self):
        # Omarchy's audio panel showed 34% while mpv's ao-volume read 32.85-34
        self.assertEqual(sxm.volume_level(34.2), 34)
        self.assertEqual(sxm.volume_level(150), 100)
        self.assertEqual(sxm.DEFAULT_VOLUME, 100)


class TimeTests(unittest.TestCase):
    def test_bad_utc_suffix(self):
        self.assertEqual(sxm.parse_time("2026-10-22T12:00:00.000+00:00Z"),
                         sxm.parse_time("2026-10-22T12:00:00Z"))

    def test_round_trip(self):
        stamp = 1792670400.5
        self.assertAlmostEqual(sxm.parse_time(sxm.iso_utc(stamp)), stamp, places=3)


class TokenTests(unittest.TestCase):
    def test_bearer_precedence_and_expiry_margin(self):
        with tempfile.TemporaryDirectory() as tmp:
            api = sxm.SxmApi(session_file=os.path.join(tmp, "s.json"), creds=lambda: None)
            now = sxm.time.time()
            api.state = {"device_grant": "dev"}
            self.assertEqual(api._bearer(), "dev")
            api.state.update(anon_token="anon", anon_expires=now + 3600)
            self.assertEqual(api._bearer(), "anon")
            api.state.update(identity_grant="ident")
            self.assertEqual(api._bearer(), "ident")
            api.state.update(access_token="acc", access_expires=now + 3600)
            self.assertEqual(api._bearer(), "acc")
            api.state.update(access_expires=now + 60)  # inside the refresh margin
            self.assertEqual(api._bearer(), "ident")

    def test_login_without_credentials_is_auth_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            api = sxm.SxmApi(session_file=os.path.join(tmp, "s.json"), creds=lambda: None)
            with self.assertRaises(sxm.AuthError):
                api.login()


if __name__ == "__main__":
    unittest.main()
