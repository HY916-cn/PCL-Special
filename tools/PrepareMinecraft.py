#!/usr/bin/env python3
"""Prepare the official Minecraft 26.3 Windows game and Java files (Python 3.9+).

Usage: python tools/PrepareMinecraft.py --output path/to/portable
Re-running verifies cached files and downloads only missing or damaged files.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import struct
import time
import urllib.request
import zipfile

VERSION = "26.3"
VERSION_SHA1 = "5df1795e16eea19d75b923d66ecca9ce183353c5"
VERSION_URL = "https://piston-meta.mojang.com/v1/packages/" + VERSION_SHA1 + "/26.3.json"
RUNTIME_SHA1 = "b374544c680d965fb5535977d7cb04c6befe1930"
RUNTIME_URL = "https://piston-meta.mojang.com/v1/packages/" + RUNTIME_SHA1 + "/manifest.json"
COMPONENT = "java-runtime-epsilon"


def safe_path(root, relative):
    parts = PurePosixPath(relative).parts
    if not parts or PurePosixPath(relative).is_absolute() or any(p in ("..", ".") or ":" in p or "\\" in p for p in parts):
        raise ValueError("Unsafe manifest path: " + relative)
    return root.joinpath(*parts)


def digest(path, algorithm="sha1"):
    result = hashlib.new(algorithm)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def download(job):
    path, info = job
    if path.is_file() and (info.get("size") is None or path.stat().st_size == info["size"]) and digest(path) == info["sha1"]:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part")
    for attempt in range(5):
        try:
            request = urllib.request.Request(info["url"], headers={"User-Agent": "PCL-Portable-Packager/1.0"})
            with urllib.request.urlopen(request, timeout=90) as source, temporary.open("wb") as target:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    target.write(chunk)
            if info.get("size") is not None and temporary.stat().st_size != info["size"]:
                raise ValueError("Size mismatch: " + str(path))
            if digest(temporary) != info["sha1"]:
                raise ValueError("SHA-1 mismatch: " + str(path))
            os.replace(temporary, path)
            return
        except Exception:
            temporary.unlink(missing_ok=True)
            if attempt == 4:
                raise
            time.sleep(2 ** attempt)


def windows_allowed(library):
    rules = library.get("rules")
    if rules is None:
        return True
    allowed = False
    for rule in rules:
        system = rule.get("os", {})
        if system.get("name", "windows") != "windows":
            continue
        if "arch" in system and re.fullmatch(system["arch"], "amd64") is None:
            continue
        if "version" in system and re.search(system["version"], "10.0.26100") is None:
            continue
        if rule.get("features"):
            continue
        allowed = rule["action"] == "allow"
    return allowed


def pe_machine(path):
    with path.open("rb") as source:
        if source.read(2) != b"MZ":
            raise ValueError("Invalid PE executable: " + str(path))
        source.seek(0x3C)
        offset = struct.unpack("<I", source.read(4))[0]
        source.seek(offset)
        if source.read(4) != b"PE\0\0":
            raise ValueError("Invalid PE signature: " + str(path))
        return struct.unpack("<H", source.read(2))[0]


def self_check():
    assert windows_allowed({})
    assert windows_allowed({"rules": [{"action": "allow", "os": {"name": "windows"}}]})
    assert not windows_allowed({"rules": [{"action": "allow", "os": {"name": "linux"}}]})
    assert not windows_allowed({"rules": [{"action": "allow", "os": {"arch": "x86"}}]})
    assert not windows_allowed({"rules": [{"action": "allow"}, {"action": "disallow", "os": {"name": "windows"}}]})
    for name in ("../escape", "/absolute", "C:/absolute", "folder\\escape"):
        try:
            safe_path(Path("root"), name)
        except ValueError:
            pass
        else:
            raise AssertionError(name)
    assert safe_path(Path("root"), "assets/objects/ab/hash") == Path("root/assets/objects/ab/hash")


def prepare(output, workers, skip_assets=False):
    output.mkdir(parents=True, exist_ok=True)
    minecraft = output / ".minecraft"
    metadata = output / "Minecraft-metadata"
    version_path = minecraft / "versions" / VERSION / (VERSION + ".json")
    runtime_manifest = metadata / "java-runtime-epsilon-windows-x64.json"
    download((version_path, {"sha1": VERSION_SHA1, "url": VERSION_URL}))
    download((runtime_manifest, {"sha1": RUNTIME_SHA1, "url": RUNTIME_URL}))
    version = json.loads(version_path.read_bytes())
    runtime = json.loads(runtime_manifest.read_bytes())
    if version["id"] != VERSION or version["javaVersion"] != {"component": COMPONENT, "majorVersion": 25}:
        raise ValueError("Unexpected Minecraft version or Java requirement")
    asset_path = minecraft / "assets" / "indexes" / (version["assetIndex"]["id"] + ".json")
    download((asset_path, version["assetIndex"]))
    assets = json.loads(asset_path.read_bytes())

    jobs = [(minecraft / "versions" / VERSION / (VERSION + ".jar"), version["downloads"]["client"])]
    libraries = []
    for library in version["libraries"]:
        if not windows_allowed(library):
            continue
        artifact = library["downloads"].get("artifact")
        if artifact:
            path = safe_path(minecraft / "libraries", artifact["path"])
            jobs.append((path, artifact))
            libraries.append((library["name"], path))
        classifier = library.get("natives", {}).get("windows")
        if classifier:
            info = library["downloads"]["classifiers"][classifier.replace("${arch}", "64")]
            jobs.append((safe_path(minecraft / "libraries", info["path"]), info))
    objects = {entry["hash"]: entry["size"] for entry in assets["objects"].values()}
    if not skip_assets:
        for sha1, size in objects.items():
            name = sha1[:2] + "/" + sha1
            jobs.append((safe_path(minecraft / "assets" / "objects", name), {"sha1": sha1, "size": size, "url": "https://resources.download.minecraft.net/" + name}))
    log_config = version.get("logging", {}).get("client", {}).get("file")
    if log_config:
        jobs.append((safe_path(minecraft / "assets" / "log_configs", log_config["id"]), log_config))
    java_root = minecraft / "versions" / VERSION / "runtime" / COMPONENT
    for name, entry in runtime["files"].items():
        path = safe_path(java_root, name)
        if entry["type"] == "directory":
            path.mkdir(parents=True, exist_ok=True)
        elif entry["type"] == "file":
            jobs.append((path, entry["downloads"]["raw"]))
        else:
            raise ValueError("Unsupported runtime entry type: " + entry["type"])
    # Deduplicate content-addressed assets and manifest destinations before workers write.
    jobs = list({str(path): (path, info) for path, info in jobs}.values())
    print("Preparing {} files ({:,} bytes), {} Windows libraries".format(len(jobs), sum(info["size"] for _, info in jobs), len(libraries)), flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(download, job): job[0] for job in jobs}
        for count, future in enumerate(concurrent.futures.as_completed(futures), 1):
            future.result()
            if count % 250 == 0 or count == len(jobs):
                print("Verified {}/{}".format(count, len(jobs)), flush=True)
    for name, entry in runtime["files"].items():
        if entry.get("executable"):
            path = safe_path(java_root, name)
            path.chmod(path.stat().st_mode | 0o111)
    if pe_machine(java_root / "bin" / "java.exe") != 0x8664 or pe_machine(java_root / "bin" / "javaw.exe") != 0x8664:
        raise ValueError("Java executable is not Windows x64")
    if 'JAVA_VERSION="25.0.1"' not in (java_root / "release").read_text():
        raise ValueError("Unexpected Java runtime release")
    native_entries = {}
    for name, path in libraries:
        with zipfile.ZipFile(path) as archive:
            corrupt = archive.testzip()
            if corrupt:
                raise ValueError("Corrupt library entry: " + corrupt)
            dlls = [entry for entry in archive.namelist() if entry.lower().endswith(".dll")]
            if dlls:
                native_entries[name] = dlls
    with zipfile.ZipFile(jobs[0][0]) as archive:
        if version["mainClass"].replace(".", "/") + ".class" not in archive.namelist():
            raise ValueError("Minecraft main class is missing")
    classpath = [path.relative_to(output).as_posix() for _, path in libraries]
    classpath.append(jobs[0][0].relative_to(output).as_posix())
    inventory = []
    metadata_jobs = [(version_path, {"sha1": VERSION_SHA1, "url": VERSION_URL}), (runtime_manifest, {"sha1": RUNTIME_SHA1, "url": RUNTIME_URL}), (asset_path, version["assetIndex"])]
    for path, info in sorted(jobs + metadata_jobs, key=lambda item: str(item[0])):
        inventory.append({"path": path.relative_to(output).as_posix(), "size": path.stat().st_size, "sha1": info["sha1"], "sha256": digest(path, "sha256"), "url": info["url"]})
    result = {"minecraft": VERSION, "platform": "windows-x64", "partial": skip_assets, "java": {"component": COMPONENT, "version": "25.0.1", "executable": (java_root / "bin" / "javaw.exe").relative_to(output).as_posix(), "manifestSha1": RUNTIME_SHA1}, "versionManifestSha1": VERSION_SHA1, "assetIndex": version["assetIndex"]["id"], "assetIndexObjects": len(objects), "assetObjects": 0 if skip_assets else len(objects), "libraryCount": len(libraries), "classpath": classpath, "nativeDlls": native_entries, "fileCount": len(inventory), "totalBytes": sum(item["size"] for item in inventory), "files": inventory}
    (output / "Minecraft-inventory.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: result[key] for key in ("minecraft", "platform", "partial", "java", "assetObjects", "libraryCount", "fileCount", "totalBytes")}, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--workers", type=int, default=16, choices=range(1, 17))
    parser.add_argument("--skip-assets", action="store_true", help="Prepare Java and classpath files for CI; omit asset objects")
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    self_check()
    if arguments.self_test:
        print("Self-check passed")
    elif arguments.output:
        prepare(arguments.output.resolve(), arguments.workers, arguments.skip_assets)
    else:
        parser.error("--output is required")
