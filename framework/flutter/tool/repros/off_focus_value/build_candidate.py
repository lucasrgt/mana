"""Build a disposable engine experiment; never patch the installed Flutter SDK.

This is a diagnostic reproducer, not a Mana build dependency or an SDK updater.
Only the engine source revision reviewed in README.md is accepted.
"""
import argparse
import difflib
import hashlib
import json
import platform
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint(directory):
    return {
        str(path.relative_to(directory)): digest(path)
        for path in sorted(directory.rglob("*")) if path.is_file()
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="New disposable directory; must not already exist")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("This diagnostic builder was validated only on Linux x86_64")
    sdk = args.flutter_sdk.resolve(strict=True)
    output = args.output.resolve()
    if output.is_relative_to(sdk):
        parser.error("Output must be outside the installed SDK")
    source = sdk / "bin/cache/flutter_web_sdk"
    dart = sdk / "bin/cache/dart-sdk"
    relative = Path("lib/_engine/engine/semantics/text_field.dart")
    expected = "560248596a0ea39f197bd327dce65940f705abe166f5301634f8f15d6f46699b"
    if digest(source / relative) != expected:
        parser.error("Engine source differs from the reviewed baseline; review before porting")
    installed_before = fingerprint(source)
    output.mkdir(parents=True, exist_ok=False)
    report = {"status": "building", "sdk": json.loads(
        (sdk / "bin/cache/flutter.version.json").read_text())}
    try:
        build = output / "engine/out/candidate"
        build.mkdir(parents=True)
        shutil.copytree(source, build / "flutter_web_sdk")
        (build / "dart-sdk").symlink_to(dart, target_is_directory=True)
        prebuilt = output / "engine/flutter/prebuilts/linux-x64"
        prebuilt.mkdir(parents=True)
        (prebuilt / "dart-sdk").symlink_to(dart, target_is_directory=True)
        target = build / "flutter_web_sdk" / relative
        before = target.read_text()
        anchor = "      SemanticsTextEditingStrategy._instance?.activate(this);\n    }"
        replacement = """      SemanticsTextEditingStrategy._instance?.activate(this);
    } else if (domDocument.activeElement != editableElement) {
      // Keep the accessible value current without changing focus or selection.
      // Active input/IME state remains owned by the editing strategy.
      EditingState(
        text: semanticsObject.value ?? '',
        baseOffset: 0,
        extentOffset: 0,
      ).applyTextToDomElement(editableElement);
    }"""
        if before.count(anchor) != 1:
            raise ValueError("Patch anchor is not unique")
        target.write_text(before.replace(anchor, replacement))
        patch = "".join(difflib.unified_diff(
            before.splitlines(True), target.read_text().splitlines(True),
            fromfile="a/" + str(relative), tofile="b/" + str(relative)))
        (output / "candidate.patch").write_text(patch)
        packages = output / "packages.json"
        packages.write_text('{"configVersion":2,"packages":[]}')
        kernel = build / "flutter_web_sdk/kernel/dart2js_platform.dill"
        command = [str(dart / "bin/dartaotruntime"),
                   str(dart / "bin/snapshots/kernel_worker_aot.dart.snapshot"),
                   "--no-summary-only", "--null-environment", "--target", "dart2js",
                   "--packages-file", str(packages), "--libraries-file",
                   str(build / "flutter_web_sdk/libraries.json"), "--output", str(kernel)]
        for library in ["core", "ui", "ui_web", "_engine", "_skwasm_stub", "_web_locale_keymap"]:
            command.extend(["--source", "dart:" + library])
        with (output / "kernel.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        app = Path(__file__).resolve().parent
        report["sources"] = {str(p.relative_to(app)): digest(p) for p in
                             [app / "lib/main.dart", app / "lib/variants.dart", app / "pubspec.lock"]}
        for name, entry in [("web", "main.dart"), ("variants", "variants.dart")]:
            with (output / (name + ".log")).open("w") as log:
                subprocess.run([
                    str(sdk / "bin/flutter"), "--local-engine-src-path=" + str(output / "engine"),
                    "--local-web-sdk=candidate", "build", "web", "--target", "lib/" + entry,
                    "--release", "--no-wasm-dry-run", "--output=" + str(output / name),
                ], cwd=app, stdout=log, stderr=subprocess.STDOUT, check=True)
            report[name] = fingerprint(output / name)
        report["kernelSha256"] = digest(kernel)
        report["patchSha256"] = digest(output / "candidate.patch")
        report["status"] = "built-not-browser-verified"
    except Exception as error:
        report["status"] = "build-failed"
        report["errorType"] = type(error).__name__
        raise
    finally:
        report["installedWebSdkUnchanged"] = fingerprint(source) == installed_before
        (output / "build.json").write_text(json.dumps(report, indent=2) + "\n")
        if not report["installedWebSdkUnchanged"]:
            raise RuntimeError("Installed web SDK changed during experiment")
    print("Candidate built; browser verification is still required:", output)


if __name__ == "__main__":
    main()
