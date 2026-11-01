#!/usr/bin/env python3
"""Append a verified distribution ZIP to the Windows PCL package launcher."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import zipfile

MAGIC = b"PCL-SINGLE-V1\0\0\0"
FOOTER = struct.Struct("<QQ16s")


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def relative(name):
    name = name.replace("\\", "/")
    for part in name.split("/"):
        if not part or part in (".", "..") or part.endswith((".", " ")) or re.search(r'[<>:"|?*\x00-\x1f]', part) or re.fullmatch(r"(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", part):
            raise ValueError("Invalid Windows package path: " + name)
    return name


def make(stub, archive, output, edition, folder, launcher):
    if "/" in relative(folder) or not edition.strip() or len(edition) > 80:
        raise ValueError("Invalid edition name or output folder")
    launcher = relative(launcher)
    if not launcher.lower().endswith(".exe"):
        raise ValueError("Expected a launcher EXE")
    if output.resolve() in (stub.resolve(), archive.resolve()):
        raise ValueError("Output must differ from inputs")
    with stub.open("rb") as source:
        if source.read(2) != b"MZ" or stub.stat().st_size < 512:
            raise ValueError("Invalid Windows launcher stub")
    with zipfile.ZipFile(archive) as package:
        corrupt = package.testzip()
        if corrupt:
            raise ValueError("Corrupt ZIP entry: " + corrupt)
        entries = [item for item in package.infolist() if not item.is_dir()]
        names = [relative(item.filename) for item in entries]
        if len(set(name.casefold() for name in names)) != len(names) or launcher not in names:
            raise ValueError("Duplicate package path or missing launcher")
        launcher_hash = hashlib.sha256(package.read(entries[names.index(launcher)])).hexdigest()
    metadata = {"edition": edition, "folder": folder, "launcher": launcher, "archiveSha256": digest(archive),
                "launcherSha256": launcher_hash, "files": names, "uncompressedBytes": sum(item.file_size for item in entries)}
    encoded = json.dumps(metadata, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > 2 * 1024 * 1024:
        raise ValueError("Single-file metadata is too large")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".part")
    try:
        with temporary.open("wb") as target:
            for source_path in (stub, archive):
                with source_path.open("rb") as source:
                    shutil.copyfileobj(source, target, 1024 * 1024)
            target.write(encoded)
            target.write(FOOTER.pack(archive.stat().st_size, len(encoded), MAGIC))
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    result = {"file": output.name, "edition": edition, "bytes": output.stat().st_size, "sha256": digest(output),
              "payloadSha256": metadata["archiveSha256"], "stubSha256": digest(stub), "files": len(names),
              "uncompressedBytes": metadata["uncompressedBytes"], "folder": folder, "launcher": launcher}
    print(json.dumps(result, ensure_ascii=True, indent=2))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("stub", "archive", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("edition", "folder", "launcher"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    make(args.stub, args.archive, args.output, args.edition, args.folder, args.launcher)
