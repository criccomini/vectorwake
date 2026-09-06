"""Exercise the release packager with a small Defold bundle."""

from html.parser import HTMLParser
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


CLIENT = Path(__file__).resolve().parents[1]


class ManifestLinks(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.hrefs = []
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "link" and "manifest" in attrs.get("rel", "").split():
            self.hrefs.append(attrs.get("href"))


class ManifestPackagingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        (self.bundle / "archive").mkdir()
        (self.bundle / "index.html").write_bytes(
            (CLIENT / "web/engine_template.html").read_bytes())
        (self.bundle / "dmloader.js").write_text(
            "var width = 1280;\n        var height = 800;")
        (self.bundle / "vectorwake_wasm.js").write_text("// test engine")
        (self.bundle / "vectorwake.wasm").write_bytes(b"\x00asm")
        (self.bundle / "archive/archive_files.json").write_text(
            '{"content": [{"pieces": [{"name": "game0.arcd"}]}]}')
        (self.bundle / "archive/game0.arcd").write_bytes(b"test archive")
        self.output = self.root / "page"
        self.output.mkdir()

    def package(self, *flags):
        subprocess.run([
            sys.executable, str(CLIENT / "tools/single_file.py"),
            str(self.bundle), str(self.output / "index.html"), *flags,
        ], check=True, capture_output=True, text=True)
        return (self.output / "index.html").read_text()

    def test_page_publishes_discoverable_manifest_and_real_icons(self):
        html = self.package()
        self.assertEqual(ManifestLinks(html).hrefs, ["/manifest.webmanifest"])
        manifest_file = self.output / "manifest.webmanifest"
        self.assertEqual(manifest_file.read_bytes(),
                         (CLIENT / "web/manifest.webmanifest").read_bytes())
        manifest = json.loads(manifest_file.read_text())
        self.assertEqual(manifest["vectorbox"]["schema_version"], "0.1")
        self.assertIs(manifest["vectorbox"]["input"]["gamepad"], True)
        self.assertEqual(manifest["start_url"], "/")
        self.assertEqual(manifest["id"], "/")
        for icon in manifest["icons"]:
            name = icon["src"].removeprefix("/")
            data = (self.output / name).read_bytes()
            self.assertEqual(data, (CLIENT / "web" / name).read_bytes())
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            width, height = struct.unpack(">II", data[16:24])
            self.assertEqual(icon["sizes"], f"{width}x{height}")
            self.assertEqual(icon["type"], "image/png")

    def test_fragment_does_not_publish_host_install_metadata(self):
        html = self.package("--fragment")
        self.assertEqual(ManifestLinks(html).hrefs, [])
        self.assertEqual([p.name for p in self.output.iterdir()], ["index.html"])
        self.assertIn('id="canvas"', html)


if __name__ == "__main__":
    unittest.main()
