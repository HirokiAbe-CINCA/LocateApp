import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "generate_sparkle_appcast.sh"


def test_generate_sparkle_appcast_uses_stdin_key_and_release_zip(tmp_path):
    release_dir = tmp_path / "release"
    release_dir.mkdir()
    archive = release_dir / "LocateApp-1.2.3-mac-arm64.zip"
    archive.write_bytes(b"zip bytes")
    (release_dir / "RELEASE_NOTES.md").write_text("# LocateApp 1.2.3\n\n- Test notes.\n")

    tools_dir = tmp_path / "sparkle"
    bin_dir = tools_dir / "bin"
    bin_dir.mkdir(parents=True)
    capture_dir = tmp_path / "capture"
    capture_dir.mkdir()
    fake_generate_appcast = bin_dir / "generate_appcast"
    fake_generate_appcast.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
cat > "$CAPTURE_DIR/stdin-key.txt"
printf '%s\n' "$@" > "$CAPTURE_DIR/args.txt"
out=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat > "$out" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>123</sparkle:version>
      <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
      <enclosure url="https://github.com/HirokiAbe-CINCA/LocateApp/releases/download/v1.2.3/LocateApp-1.2.3-mac-arm64.zip" sparkle:edSignature="sig" length="9" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
"""
    )
    fake_generate_appcast.chmod(0o755)

    env = {
        **os.environ,
        "VERSION": "1.2.3",
        "RELEASE_DIR": str(release_dir),
        "SPARKLE_TOOLS_DIR": str(tools_dir),
        "SPARKLE_ED_PRIVATE_KEY": "private-key",
        "CAPTURE_DIR": str(capture_dir),
    }
    result = subprocess.run([str(SCRIPT)], env=env, text=True, capture_output=True)

    assert result.returncode == 0, result.stderr
    assert (release_dir / "appcast.xml").exists()
    assert (capture_dir / "stdin-key.txt").read_text() == "private-key"
    args = (capture_dir / "args.txt").read_text()
    assert "--ed-key-file\n-\n" in args
    assert "--download-url-prefix\nhttps://github.com/HirokiAbe-CINCA/LocateApp/releases/download/v1.2.3/\n" in args
    staged_notes = tmp_path / "build" / "sparkle-appcast" / "LocateApp-1.2.3-mac-arm64.md"
    assert staged_notes.read_text() == "# LocateApp 1.2.3\n\n- Test notes.\n"


def test_generate_sparkle_appcast_requires_private_key(tmp_path):
    release_dir = tmp_path / "release"
    release_dir.mkdir()
    (release_dir / "LocateApp-1.2.3-mac-arm64.zip").write_bytes(b"zip bytes")

    env = {
        **os.environ,
        "VERSION": "1.2.3",
        "RELEASE_DIR": str(release_dir),
        "SPARKLE_TOOLS_DIR": str(tmp_path / "sparkle"),
    }
    env.pop("SPARKLE_ED_PRIVATE_KEY", None)

    result = subprocess.run([str(SCRIPT)], env=env, text=True, capture_output=True)

    assert result.returncode != 0
    assert "SPARKLE_ED_PRIVATE_KEY" in result.stderr
