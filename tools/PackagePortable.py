#!/usr/bin/env python3
"""Package verified Minecraft 26.3 files and a built PCL特别版 for Windows x64."""

import argparse
import json
from pathlib import Path
import shutil
import zipfile

from PrepareMinecraft import VERSION, digest, safe_path

NAME = "PCL特别版-2.99.99"
PACKAGE = NAME + "-Minecraft26.3-便携包"


def package(minecraft, dist, output):
    inventory = json.loads((minecraft / "Minecraft-inventory.json").read_text(encoding="utf-8"))
    if inventory["minecraft"] != VERSION or inventory["platform"] != "windows-x64" or inventory["partial"]:
        raise ValueError("The full Windows x64 Minecraft 26.3 payload is required")
    if inventory["assetObjects"] != inventory["assetIndexObjects"] or inventory["assetObjects"] < 1:
        raise ValueError("Incomplete Minecraft asset inventory")
    hashes = {}
    for line in (dist / "SHA256SUMS.txt").read_text(encoding="utf-8-sig").splitlines():
        sha256, name = line.split("  ", 1)
        hashes[name] = sha256
    files = [(NAME + ".exe", "PCL.exe"), (NAME + ".exe.config", "PCL.exe.config"),
             (NAME + "-Source.zip", NAME + "-Source.zip"), ("LICENCE", "LICENCE"),
             ("SOURCE.txt", "SOURCE.txt"), ("使用说明.md", "启动器使用说明.md")]
    files.extend((name, name) for name in sorted(hashes) if name.startswith("LinkModules/"))
    if not any(name == "LinkModules/easytier-windows-x86_64-v2.6.4.zip" for name, _ in files):
        raise ValueError("The verified multiplayer module is required")
    stage = output / PACKAGE
    if stage.exists():
        raise FileExistsError("Use a fresh output directory: " + str(stage))
    # Validate every input before creating the deliverable.
    for entry in inventory["files"]:
        path = safe_path(minecraft, entry["path"])
        if path.stat().st_size != entry["size"] or digest(path) != entry["sha1"] or digest(path, "sha256") != entry["sha256"]:
            raise ValueError("Minecraft hash mismatch: " + entry["path"])
    for name, _ in files:
        if digest(safe_path(dist, name), "sha256") != hashes[name]:
            raise ValueError("Launcher package hash mismatch: " + name)
    stage.mkdir(parents=True)
    for entry in inventory["files"]:
        target = safe_path(stage, entry["path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(safe_path(minecraft, entry["path"]), target)
    shutil.copy2(minecraft / "Minecraft-inventory.json", stage / "Minecraft-inventory.json")
    for name, destination in files:
        target = safe_path(stage, destination)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(safe_path(dist, name), target)
    configs = {
        "PCL/Setup.ini": "LaunchFolderSelect:$.minecraft\\\r\n",
        ".minecraft/PCL.ini": "Version:26.3\r\n",
        ".minecraft/versions/26.3/PCL/Setup.ini": "VersionArgumentJavaV2:2\r\nVersionArgumentIndieV2:False\r\n",
    }
    for name, text in configs.items():
        path = safe_path(stage, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode("utf-8"))
    (stage / "启动26.3.cmd").write_bytes(b'@echo off\r\ncd /d "%~dp0"\r\nstart "" "%~dp0PCL.exe" --launch=26.3\r\n')
    (stage / "开始使用.txt").write_text(
        "PCL特别版 2.99.99 · Minecraft 26.3 便携包\n制作开发者：Haoyu Huang\n\n"
        "适用：Windows x64、.NET Framework 4.8。完整解压到独立文件夹后，双击“启动26.3.cmd”。\n"
        "首次请自行确认用户协议，在“正版”中使用拥有 Minecraft Java 版的微软账号登录，然后点击“启动游戏”。\n"
        "以后使用该入口，在账号资料可用时会自动启动 26.3；直接打开 PCL.exe 可进入常规启动器。\n"
        "游戏、Windows 支持库、完整资源和 Java 25.0.1 已随包提供；联机模块首次使用时从本地安装。\n"
        "登录与在线功能仍需联网。额外组件、模组、资源包需要另行下载。\n"
        "Minecraft-inventory.json 列出官方文件来源与校验值，SHA256SUMS.txt 校验整个便携目录。\n"
        "启动器说明和源码随包提供，原作者与许可见 LICENCE、SOURCE.txt 和 LinkModules 中的说明。\n",
        encoding="utf-8-sig")
    paths = sorted(path for path in stage.rglob("*") if path.is_file())
    (stage / "SHA256SUMS.txt").write_text("".join(digest(path, "sha256") + "  " + path.relative_to(stage).as_posix() + "\n" for path in paths), encoding="utf-8")
    archive_path = output / (PACKAGE + ".zip")
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(stage).as_posix())
    with zipfile.ZipFile(archive_path) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError("Corrupt ZIP entry: " + corrupt)
    result = {"package": archive_path.name, "minecraft": VERSION, "platform": "windows-x64",
              "files": len(paths) + 1, "bytes": archive_path.stat().st_size,
              "sha256": digest(archive_path, "sha256"), "gameFilesVerified": inventory["fileCount"],
              "assetObjects": inventory["assetObjects"], "java": inventory["java"]["version"]}
    (output / "portable-package-result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minecraft", type=Path, required=True)
    parser.add_argument("--dist", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.minecraft.resolve(), args.dist.resolve(), args.output.resolve())
