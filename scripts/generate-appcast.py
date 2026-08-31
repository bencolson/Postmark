#!/usr/bin/env python3
"""Generates a Sparkle-compatible appcast feed for Postmark from GitHub releases.

Public GitHub release metadata already carries everything a Sparkle feed needs
(short version string, DMG download URL, release notes). This script renders
that into a `appcast.xml` at the repo root, ready to publish via GitHub Pages
or raw.githubusercontent.com — see the Makefile `appcast` target.

   make appcast        -> python3 scripts/generate-appcast.py

Requires `gh` to be authenticated, or a GITHUB_TOKEN in the environment.
If SPARKLE_PRIV_KEY (the Sparkle EdDSA private key) is present, the DMG's
signature is generated with `./bin/sign_update` (from the Sparkle binary
distribution). Without it, the feed carries an empty signature — Sparkle
clients will see the update but refuse to install unless signed.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime

REPO = "bencolson/Postmark"
BASE_URL = f"https://api.github.com/repos/{REPO}"
DMG_NAME = "Postmark.dmg"


def api(path: str) -> dict | list:
    req = urllib.request.Request(f"{BASE_URL}/{path}", headers={"Accept": "application/vnd.github+json"})
    if token := os.environ.get("GITHUB_TOKEN"):
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"Repository {REPO} not found or has no releases yet — publish a release on GitHub first.")
            sys.exit(1)
        raise


def sign(dmg_url: str) -> str:
    """Best-effort EdDSA signature of the DMG when a Sparkle key is available."""
    key = os.environ.get("SPARKLE_PRIV_KEY")
    if not key:
        print("⚠️  SPARKLE_PRIV_KEY not set — appcast will carry an empty signature")
        return ""
    return subprocess.run(
        ["bin/sign_update", dmg_url, key], capture_output=True, text=True, check=True
    ).stdout.strip()


def main() -> int:
    releases = api("releases")
    if not isinstance(releases, list) or not releases:
        print("No GitHub releases found. Publish a release first.")
        return 1

    root = ET.Element(
        "rss",
        {"xmlns:sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle",
         "xmlns:dc": "http://purl.org/dc/elements/1.1/", "version": "2.0"},
    )
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Postmark"
    ET.SubElement(channel, "description").text = "Inbox triage + call-sheet forwarding for Apple Mail."
    ET.SubElement(channel, "language").text = "en"

    for release in releases:
        if release.get("draft"):
            continue
        tag = release.get("tag_name") or ""
        version = tag[1:] if tag.startswith("v") else tag
        published = release.get("published_at") or ""

        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = version
        ET.SubElement(item, "sparkle:version").text = version
        ET.SubElement(item, "sparkle:shortVersionString").text = version
        ET.SubElement(item, "sparkle:minimumSystemVersion").text = "14.0"
        ET.SubElement(item, "sparkle:releaseNotesLink").text = release["html_url"]
        ET.SubElement(item, "pubDate").text = (
            datetime.fromisoformat(published.replace("Z", "+00:00")).strftime("%a, %d %b %Y %H:%M:%S %z")
            if published else "Mon, 01 Jan 2026 00:00:00 +0000"
        )
        ET.SubElement(item, "link").text = release["html_url"]

        for asset in release.get("assets", []):
            if asset.get("name") == DMG_NAME:
                url = asset["browser_download_url"]
                enclosure = ET.SubElement(
                    item, "enclosure",
                    {
                        "url": url,
                        "sparkle:edSignature": sign(url),
                        "sparkle:dsaSignature": "",
                        "length": str(asset.get("size", 0)),
                        "type": "application/octet-stream",
                    },
                )
                break

    ET.indent(root, space="  ")
    tree = ET.ElementTree(root)
    tree.write("appcast.xml", encoding="utf-8", xml_declaration=True)
    print("✅ Wrote appcast.xml")
    return 0


if __name__ == "__main__":
    sys.exit(main())