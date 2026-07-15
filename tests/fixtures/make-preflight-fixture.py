#!/usr/bin/env python3
"""Create a small, internally consistent OCI index for preflight tests."""

import argparse
import hashlib
import io
import json
import tarfile
import tempfile
from pathlib import Path

IMAGE_INDEX = "application/vnd.oci.image.index.v1+json"
IMAGE_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
IMAGE_CONFIG = "application/vnd.oci.image.config.v1+json"
ZSTD_MARKER = "io.github.containers.compression.zstd"


def encoded(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()


def descriptor(media_type, contents, annotations=None):
    value = {
        "mediaType": media_type,
        "digest": f"sha256:{hashlib.sha256(contents).hexdigest()}",
        "size": len(contents),
    }
    if annotations is not None:
        value["annotations"] = annotations
    return value


def write_blob(root, contents):
    digest = hashlib.sha256(contents).hexdigest()
    path = root / "blobs" / "sha256" / digest
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(contents)


def write_archive(root, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, "w", format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(item for item in root.rglob("*") if item.is_file()):
            name = path.relative_to(root).as_posix()
            info = tarfile.TarInfo(name)
            contents = path.read_bytes()
            info.size = len(contents)
            info.mode = 0o644
            info.mtime = 0
            archive.addfile(info, fileobj=io.BytesIO(contents))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--metrics", required=True, type=Path)
    parser.add_argument("--profile", default="5.1")
    parser.add_argument("--omit-zstd-marker", action="store_true")
    parser.add_argument("--mismatch-zstd-digest", action="store_true")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="preflight-fixture-") as directory:
        root = Path(directory)
        config = encoded(
            {
                "architecture": "amd64",
                "config": {},
                "os": "linux",
                "rootfs": {"diff_ids": [], "type": "layers"},
            }
        )
        config_descriptor = descriptor(IMAGE_CONFIG, config)
        manifest = encoded(
            {
                "config": config_descriptor,
                "layers": [],
                "mediaType": IMAGE_MANIFEST,
                "schemaVersion": 2,
            }
        )
        annotations = {} if args.omit_zstd_marker else {ZSTD_MARKER: "true"}
        manifest_descriptor = descriptor(IMAGE_MANIFEST, manifest, annotations)
        combined = encoded(
            {
                "manifests": [manifest_descriptor],
                "mediaType": IMAGE_INDEX,
                "schemaVersion": 2,
            }
        )
        root_index = encoded(
            {
                "manifests": [descriptor(IMAGE_INDEX, combined)],
                "mediaType": IMAGE_INDEX,
                "schemaVersion": 2,
            }
        )

        for contents in (config, manifest, combined):
            write_blob(root, contents)
        (root / "index.json").write_bytes(root_index)
        (root / "oci-layout").write_text(
            '{"imageLayoutVersion":"1.0.0"}', encoding="utf-8"
        )
        write_archive(root, args.archive)

    archive_contents = args.archive.read_bytes()
    manifest_digest = manifest_descriptor["digest"]
    if args.mismatch_zstd_digest:
        manifest_digest = f"sha256:{'0' * 64}"
    metrics = {
        "schema_version": 1,
        "profile": args.profile,
        "content": {"zstd_chunked_manifest_digest": manifest_digest},
        "archives": {
            "index": {
                "bytes": len(archive_contents),
                "sha256": hashlib.sha256(archive_contents).hexdigest(),
            }
        },
    }
    args.metrics.parent.mkdir(parents=True, exist_ok=True)
    args.metrics.write_text(
        json.dumps(metrics, separators=(",", ":")), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
