#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import tarfile
import urllib.parse
import urllib.request
from pathlib import Path


REPO = "tldev/openinterstate"


def _auth_headers() -> dict[str, str]:
    """Build HTTP headers, adding Authorization if GITHUB_TOKEN is set."""
    headers: dict[str, str] = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "pike-openinterstate-fetch/1.0",
    }
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if token:
        headers["Authorization"] = f"token {token}"
    return headers


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Resolve, download, and extract an OpenInterstate release"
    )
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--release-tag")
    args = parser.parse_args()

    cache_dir = Path(args.cache_dir).expanduser().resolve()
    cache_dir.mkdir(parents=True, exist_ok=True)

    print(json.dumps(resolve_github_release(cache_dir, args.release_tag), sort_keys=True))
    return 0


def resolve_github_release(cache_dir: Path, release_tag: str | None) -> dict[str, str]:
    release_json = fetch_release_json(release_tag)
    release_id = release_json["tag_name"]

    asset_map = {
        asset["name"]: asset["browser_download_url"]
        for asset in release_json.get("assets", [])
    }

    tarball_name = f"openinterstate-{release_id}.tar.gz"
    if tarball_name not in asset_map:
        raise SystemExit(f"release {release_id} is missing required asset: {tarball_name}")

    tarball_path = cache_dir / tarball_name
    download(asset_map[tarball_name], tarball_path)

    extracted_root = cache_dir / "extracted"
    extracted_root.mkdir()
    with tarfile.open(tarball_path, "r:gz") as archive:
        safe_extract(archive, extracted_root)

    return {
        "OPENINTERSTATE_RELEASE_ID": release_id,
        "OPENINTERSTATE_RELEASE_DIR": str(locate_release_dir(extracted_root)),
    }


def fetch_release_json(release_tag: str | None) -> dict:
    if release_tag:
        encoded = urllib.parse.quote(release_tag, safe="")
        url = f"https://api.github.com/repos/{REPO}/releases/tags/{encoded}"
    else:
        url = f"https://api.github.com/repos/{REPO}/releases/latest"

    request = urllib.request.Request(url, headers=_auth_headers())
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers=_auth_headers())
    with urllib.request.urlopen(request) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def locate_release_dir(root: Path) -> Path:
    candidates = [path.parent for path in root.rglob("manifest.json")]
    if len(candidates) != 1:
        raise SystemExit(
            f"expected one extracted release directory under {root}, found {len(candidates)}"
        )
    return candidates[0]


def safe_extract(archive: tarfile.TarFile, destination: Path) -> None:
    destination = destination.resolve()
    for member in archive.getmembers():
        target = (destination / member.name).resolve()
        if os.path.commonpath([destination, target]) != str(destination):
            raise SystemExit(f"unsafe tar member path: {member.name}")
    archive.extractall(destination)


if __name__ == "__main__":
    raise SystemExit(main())
