# Security

Kiri opens files from anywhere and updates itself, so a hole in it matters. Thank you for telling us about one.

## Reporting a vulnerability

Report it privately: [**Report a vulnerability**](https://github.com/ErikHellman/kiri/security/advisories/new) (the repo's Security tab ▸ Advisories). Only the maintainer sees the report. Please don't open a public issue or pull request for it.

It helps to say:

- the version of Kiri (Kiri ▸ About Kiri) and of macOS;
- what an attacker can do, and what the person using Kiri has to do for it to work (open a file, click a link, nothing);
- the steps, with a file that shows it if there is one.

A fix goes out as a new version, which Kiri installs by itself, and the advisory is published with it, with your name if you want it there.

## Supported versions

Only the [latest release](https://github.com/ErikHellman/kiri/releases/latest) gets fixes: Kiri updates itself, so that is the version to be on.

## What counts

Anything that lets a file, a link, an update or the `kiri` command do more than it should: run code, read or write files it wasn't asked to, send something off the Mac without being asked, or get a build onto a Mac that the release job didn't make. Crashes on a crafted file count too.
