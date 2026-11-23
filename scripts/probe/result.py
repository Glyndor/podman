#!/usr/bin/env python3
"""Turn the facts of one probe run into result.json and a row of the job summary.

Usage: result.py <name> <image> <output directory>

The steps write facts.tsv (key, tab, value; the last value of a key wins), logs/ and,
when a step failed, first-error.txt. Nothing here decides anything the steps did not
record: a fact that is missing is reported as unknown, not as a failure or a success.
"""

import json
import os
import sys

BOOT_ROOT = ("info", "pull", "root-run", "root-bridge")
BOOT_ROOTLESS = ("rootless-userns", "rootless-run", "rootless-net")
COMPONENTS = ("podman", "netavark", "aardvark-dns")


def read_facts(path):
    facts = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                key, _, value = line.rstrip("\n").partition("\t")
                if key:
                    facts[key] = value
    return facts


def flag(facts, key):
    value = facts.get(key)
    if value is None:
        return None
    return value.split(" ", 1)[0] == "ok"


def dependencies(facts):
    out = []
    for key, value in facts.items():
        if key.startswith("dep."):
            have, need, verdict, source = (value.split("|") + ["", "", "", ""])[:4]
            out.append({"name": key[4:], "distribution_version": have, "needed": need,
                        "verdict": verdict, "package": source})
    return out


def build(name, image, out_dir):
    facts = read_facts(os.path.join(out_dir, "facts.tsv"))
    error_path = os.path.join(out_dir, "first-error.txt")
    first_error = None
    if os.path.exists(error_path):
        with open(error_path, encoding="utf-8", errors="replace") as f:
            first_error = f.read()

    components = {c: flag(facts, "build." + c) for c in COMPONENTS}
    boot = {k[5:]: v for k, v in facts.items() if k.startswith("boot.")}
    root_ok = all(flag(facts, "boot." + k) for k in BOOT_ROOT)
    rootless_ok = all(flag(facts, "boot." + k) for k in BOOT_ROOTLESS)
    dns_root = flag(facts, "boot.root-dns")
    dns_rootless = flag(facts, "boot.rootless-dns")
    built = all(components.values())
    enters = bool(built and flag(facts, "install") and root_ok and rootless_ok and dns_root and dns_rootless)
    decided = all(v is not None for v in components.values()) and "step.05-boot" in facts
    return {
        "distribution": name,
        "image": image,
        "os": facts.get("os.pretty"),
        "kernel": facts.get("os.kernel"),
        "compiles": components,
        "toolchain": {"go": facts.get("toolchain.go"), "rust": facts.get("toolchain.rust")},
        "headers_missing": facts.get("toolchain.headers-missing"),
        "dependencies": dependencies(facts),
        "built_from_source_here": {k[6:]: v for k, v in facts.items()
                                   if k in ("build.passt", "build.crun", "build.conmon", "build.catatonit")},
        "installs": flag(facts, "install"),
        "installed": {k[8:]: v for k, v in facts.items() if k.startswith("install.")},
        "boot": boot,
        "starts_as_root": root_ok,
        "starts_rootless": rootless_ok,
        "dns_root": dns_root,
        "dns_rootless": dns_rootless,
        "steps": {k[5:]: v for k, v in facts.items() if k.startswith("step.")},
        "verdict": "enters" if enters else ("does not enter" if decided or first_error else "incomplete"),
        "first_error": first_error,
    }


def mark(value):
    return {True: "yes", False: "NO", None: "n/a"}[value]


def main():
    name, image, out_dir = sys.argv[1:4]
    result = build(name, image, out_dir)
    with open(os.path.join(out_dir, "result.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
        f.write("\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        c = result["compiles"]
        row = (f"| {name} | {mark(c['podman'])} | {mark(c['netavark'])} | {mark(c['aardvark-dns'])} "
               f"| {mark(result['installs'])} | {mark(result['starts_as_root'])} "
               f"| {mark(result['starts_rootless'])} | {mark(result['dns_root'])}/{mark(result['dns_rootless'])} "
               f"| {result['verdict']} |\n")
        head = ("| distribution | podman | netavark | aardvark-dns | installs | root | rootless "
                "| dns root/rootless | verdict |\n|---|---|---|---|---|---|---|---|---|\n")
        with open(summary, "a", encoding="utf-8") as f:
            f.write(head + row)
            if result["first_error"]:
                f.write("\n<details><summary>first error</summary>\n\n```\n"
                        + result["first_error"] + "\n```\n</details>\n")


if __name__ == "__main__":
    main()
