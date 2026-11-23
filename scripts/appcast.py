#!/usr/bin/env python3
"""Writes Kiri's Sparkle appcast: one item, the newest release.

Sparkle only needs the newest version, so the feed is just that, attached
to each release as appcast.xml; .../releases/latest/download/appcast.xml
then always answers with the newest one. Used by
.github/workflows/release.yml:

    scripts/appcast.py --version 0.2.0 --build 41 \\
        --url https://github.com/OWNER/kiri-releases/releases/download/v0.2.0/Kiri-0.2.0.dmg \\
        --dmg build/Kiri-0.2.0.dmg --signature BASE64 \\
        --minimum-system 26.0 --notes notes.md --output build/appcast.xml

With --public-key, the signature is first checked against that key (the
app's SUPublicEDKey) the way Sparkle will check it, so a release signed
with the wrong private key fails here instead of on everyone's Mac. That
check needs the `cryptography` package.
"""

import argparse
import base64
import email.utils
import html
import os
import re
import sys
import time
from xml.sax.saxutils import escape, quoteattr

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def notes_html(text):
    """A little Markdown, enough for release notes: paragraphs, "- " lists,
    `code`, **bold** and [links](url)."""

    def inline(line):
        line = html.escape(line, quote=False)
        line = re.sub(r"`([^`]+)`", r"<code>\1</code>", line)
        line = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", line)
        line = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', line)
        return line

    out, para, items = [], [], []

    def flush():
        if para:
            out.append("<p>" + " ".join(inline(l) for l in para) + "</p>")
            para.clear()
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            flush()
        elif line.startswith(("- ", "* ")):
            if para:
                flush()
            items.append(line[2:].strip())
        elif line.startswith("#"):
            flush()
            out.append("<h3>" + inline(line.lstrip("#").strip()) + "</h3>")
        elif items:
            items[-1] += " " + line
        else:
            para.append(line)
    flush()
    return "\n".join(out)


def verify(path, signature, public_key):
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key))
    with open(path, "rb") as f:
        data = f.read()
    try:
        key.verify(base64.b64decode(signature), data)
    except InvalidSignature:
        sys.exit(
            f"The EdDSA signature of {os.path.basename(path)} doesn't match the app's SUPublicEDKey: "
            "SPARKLE_PRIVATE_KEY and KIRI_SPARKLE_PUBLIC_KEY are not one key pair."
        )


def appcast(version, build, url, length, signature, minimum_system, notes, pub_date):
    description = ""
    if notes.strip():
        body = notes_html(notes).replace("]]>", "]]]]><![CDATA[>")
        description = f"\n      <description><![CDATA[\n{body}\n      ]]></description>"
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
  <channel>
    <title>Kiri</title>
    <item>
      <title>{escape(f"Kiri {version}")}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum_system)}</sparkle:minimumSystemVersion>{description}
      <enclosure url={quoteattr(url)} length="{length}" type="application/octet-stream" sparkle:edSignature={quoteattr(signature)} />
    </item>
  </channel>
</rss>
"""


def main():
    p = argparse.ArgumentParser(description="Write Kiri's Sparkle appcast.")
    p.add_argument("--version", required=True, help="CFBundleShortVersionString, e.g. 0.2.0")
    p.add_argument("--build", required=True, help="CFBundleVersion, which Sparkle compares")
    p.add_argument("--url", required=True, help="where the disk image is downloaded from")
    p.add_argument("--dmg", required=True, help="the disk image, for its length (and the check)")
    p.add_argument("--signature", required=True, help="sign_update's sparkle:edSignature")
    p.add_argument("--minimum-system", default="26.0")
    p.add_argument("--notes", help="a Markdown file with the release notes")
    p.add_argument("--public-key", help="SUPublicEDKey to check the signature against")
    p.add_argument("--output", required=True)
    a = p.parse_args()

    if not a.build.isdigit():
        sys.exit(f"--build must be a whole number, not {a.build!r}")
    if a.public_key:
        verify(a.dmg, a.signature, a.public_key)
    notes = ""
    if a.notes and os.path.exists(a.notes):
        with open(a.notes, encoding="utf-8") as f:
            notes = f.read()
    xml = appcast(
        a.version, a.build, a.url, os.path.getsize(a.dmg), a.signature, a.minimum_system, notes,
        email.utils.formatdate(time.time(), usegmt=True),
    )
    with open(a.output, "w", encoding="utf-8") as f:
        f.write(xml)


if __name__ == "__main__":
    main()
