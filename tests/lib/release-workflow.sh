# shellcheck shell=bash
#
# What the suites of tests/workflows/release/ share when they read .github/workflows/release.yml: the rules that are
# run over the workflow (`violations`) and the copy of the workflows with one control broken (`sabotage`). Sourced, never
# run, with HERE and WORK set by the suite.

# violations <rule> [workflow-dir]: prints one line per violation of a rule over
# release.yml. The directory is a parameter so a rule can run on a copy that breaks
# it. A rule that cannot run prints "rule failed", so a crash is never read as none.
violations() {
	python3 - "$1" "${2:-$HERE/.github/workflows}/release.yml" 2>&1 <<'PY' || echo "rule failed"
import re, sys, yaml

rule, path = sys.argv[1:3]
with open(path) as fh:
    jobs = yaml.safe_load(fh)["jobs"]
GUARD = "github.ref == 'refs/heads/main'"
# publish never runs in a rehearsal, and the check that ends a rehearsal runs only in one.
EXTRA = {"publish": " && needs.plan.outputs.dry_run != 'true'", "rehearsal": " && needs.plan.outputs.dry_run == 'true'"}

if rule == "guard":
    # plan, sign and publish always, and any other job that can write to the repository:
    # a dispatch from a branch must not tag or sign an unreviewed commit.
    needs = {"plan", "sign", "publish", "rehearsal"}
    for name, cfg in jobs.items():
        perms = cfg.get("permissions") or {}
        if perms.get("contents") == "write" or perms.get("attestations") == "write":
            needs.add(name)
    for name in sorted(needs):
        if name not in jobs:
            print(f"job {name} is missing")
        elif str(jobs[name].get("if", "")).strip() not in (GUARD, GUARD + EXTRA.get(name, "\0")):
            print(f"job {name} does not carry the main-only guard")
elif rule == "environment":
    # A job that names a secret declares the environment whose policy releases it: the `if:` of a workflow is
    # a line a branch can delete, and the policy of an environment is not in the workflow. Every workflow of
    # the directory is read, not only release.yml.
    import glob, json, os
    for path in sorted(glob.glob(os.path.join(os.path.dirname(sys.argv[2]), "*.y*ml"))):
        for name, cfg in (yaml.safe_load(open(path))["jobs"] or {}).items():
            # Only inside an expression: `check-secrets.sh` is a file name, not a secret.
            names = [n for e in re.findall(r"\$\{\{.*?\}\}", json.dumps(cfg)) for n in re.findall(r"(?<![\w.-])secrets\.([A-Za-z_][A-Za-z0-9_]*)", e)]
            names = [n for n in names if n != "GITHUB_TOKEN"]
            if names and not cfg.get("environment"):
                print(f"{os.path.basename(path)}: job {name} names the secret {names[0]} and declares no environment")
            if names and cfg.get("environment") != "release":
                if cfg.get("environment"):
                    print(f"{os.path.basename(path)}: job {name} names a secret and declares the environment {cfg['environment']!r}, not release")
elif rule == "rehearsal":
    # A rehearsal reads no signing secret, attests nothing and creates nothing: the one job that
    # can hold a signing secret is sign, and it gives the step an empty string in a rehearsal.
    import json
    for name, cfg in jobs.items():
        text = json.dumps(cfg)
        if "secrets.GLYNDOR_RELEASE" in text and name != "sign":
            print(f"{name} reads a signing secret")
    sign_env = [s.get("env") or {} for s in jobs["sign"]["steps"]]
    keys = [e for e in sign_env if any("secrets.GLYNDOR_RELEASE" in str(v) for v in e.values())]
    if len(keys) != 1:
        print(f"{len(keys)} steps of sign read the signing secrets, expected 1")
    else:
        for k, v in keys[0].items():
            if "secrets.GLYNDOR_RELEASE" in str(v) and not str(v).startswith("${{ needs.plan.outputs.dry_run != 'true' && "):
                print(f"{k} is read in a rehearsal")
    r = jobs.get("rehearsal")
    if r is None:
        print("job rehearsal is missing")
    else:
        if (r.get("permissions") or {}) != {"contents": "read"}:
            print("rehearsal holds more than contents: read")
        for s in r["steps"]:
            if "attest" in str(s.get("uses", "")) or "release create" in str(s.get("run", "")):
                print("rehearsal attests or creates a release")
            if str(s.get("uses", "")).startswith("actions/checkout@") and "ref" in (s.get("with") or {}):
                print("rehearsal checks out a ref that is not the event's own")
elif rule == "attest":
    cfg = jobs["publish"]
    steps = cfg["steps"]
    perms = cfg.get("permissions") or {}
    for p in ("id-token", "attestations"):
        if perms.get(p) != "write":
            print(f"publish lacks {p}: write, which the attestation needs")
    hits = [i for i, s in enumerate(steps)
            if re.fullmatch(r"actions/attest-build-provenance@[0-9a-f]{40}", str(s.get("uses", "")))]
    if len(hits) != 1:
        print(f"{len(hits)} steps attest the build provenance, expected 1")
    else:
        i = hits[0]
        subject = str((steps[i].get("with") or {}).get("subject-path", ""))
        if subject != "${{ runner.temp }}/signed/*":
            print(f"the attestation subject is {subject!r}, not every file of the signed set")
        verify = [n for n, s in enumerate(steps) if s.get("name") == "Verify every signature against the published keys"]
        create = [n for n, s in enumerate(steps) if s.get("name") == "Create the release"]
        if not verify or not create or not (verify[0] < i < create[0]):
            print("the attestation is not between the verification of the signatures and the release")
        if any("GLYNDOR_RELEASE" in str(x.get("env", "")) for x in [cfg] + steps):
            print("publish holds a signing key")
elif rule == "previous":
    # What the plan read about the newest release reaches the signing step as it was
    # read: a literal there would decide the downgrade rule for every run.
    want = "${{ steps.p.outputs.previous_mldsa }}"
    if str((jobs["plan"].get("outputs") or {}).get("previous_mldsa", "")) != want:
        print(f"plan does not hand on previous_mldsa as {want}")
    want = "${{ needs.plan.outputs.previous_mldsa }}"
    if str((jobs["sign"].get("env") or {}).get("PREVIOUS_MLDSA", "")) != want:
        print(f"sign does not take PREVIOUS_MLDSA from {want}")
elif rule == "checkout":
    # No job of release.yml checks out a ref it was handed: the checkout is the commit of the event, and the jobs that
    # sign and publish compare it with the commit the plan resolved in the very next step, before any code of the
    # repository runs. A ref taken from an output is what CodeQL reads as untrusted code in a job that uploads an artifact.
    for name, cfg in jobs.items():
        for s in cfg.get("steps") or []:
            if str(s.get("uses", "")).startswith("actions/checkout@") and "ref" in (s.get("with") or {}):
                print(f"{name} checks out a ref")
    for name in ("sign", "publish"):
        cfg = jobs[name]
        steps = cfg["steps"]
        at = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("actions/checkout@")]
        if len(at) != 1:
            print(f"{name} has {len(at)} checkouts, expected 1")
            continue
        nxt = steps[at[0] + 1]
        run = str(nxt.get("run", ""))
        if "git rev-parse HEAD" not in run or '"$SHA"' not in run or "exit 1" not in run:
            print(f"{name}: the step after the checkout does not refuse a HEAD that is not the commit the plan resolved")
        if str((cfg.get("env") or {}).get("SHA", "")) != "${{ needs.plan.outputs.sha }}":
            print(f"{name} does not take SHA from the plan")
elif rule == "isolation":
    # What a job that signs or publishes may do with what the build jobs handed it. The
    # artifacts are third-party output: they are downloaded one by name, outside the
    # checkout, and nothing that runs while a key is in the environment installs, imports
    # or starts an interpreter in the directory that holds them.
    held = re.compile(r"secrets\.GLYNDOR_RELEASE")
    for name in ("sign", "publish"):
        for step in jobs[name]["steps"]:
            label = step.get("name") or step.get("uses") or "a step"
            with_ = step.get("with") or {}
            is_download = str(step.get("uses", "")).startswith("actions/download-artifact")
            if is_download:
                # The signer takes one artifact by the id the step before looked up in this run, and the download
                # checks the digest GitHub recorded for it; publish takes the one the signer made, by name. A
                # pattern, a list of ids or a name for the signer would take whatever matched.
                ids = str(with_.get("artifact-ids", ""))
                if name == "sign":
                    if not re.fullmatch(r"\$\{\{ needs\.(build-amd64|build-arm64|rpm)\.outputs\.artifact_id \}\}", ids):
                        print(f"{name}: a download takes no artifact by the id a build job reported")
                    if with_.get("name") or with_.get("pattern"):
                        print(f"{name}: a download takes artifacts by name or pattern")
                    if with_.get("digest-mismatch") != "error":
                        print(f"{name}: a download does not fail on a digest that differs")
                else:
                    if not with_.get("name"):
                        print(f"{name}: a download takes no artifact by name")
                    if ids or with_.get("pattern"):
                        print(f"{name}: a download takes more than one artifact")
                if "merge-multiple" in with_ and not (name == "sign" and ids):
                    print(f"{name}: {label} merges artifacts into one directory")
                if not str(with_.get("path", "")).startswith("${{ runner.temp }}/"):
                    print(f"{name}: a download goes somewhere other than runner.temp")
            run = str(step.get("run", ""))
            keyed = bool(held.search(str(step.get("env", ""))))
            if keyed and re.search(r"\bpip\b|-m venv", run):
                print(f"{name}: {label} installs or builds an environment with a key in the environment")
            if keyed and re.search(r"working-directory", str(step)) and re.search(r"built|signed|stage", str(step.get("working-directory", ""))):
                print(f"{name}: {label} runs in a directory that holds artifacts")
            for line in run.split("\n"):
                code = line.split("#", 1)[0]
                if re.search(r'(?:"\$py"|\bpython3?)\s', code) and " -I " not in code:
                    print(f"{name}: {label} starts Python without -I: {code.strip()[:60]}")
PY
}

# sabotage <file> <old> <new> <dir>: a copy of the workflows in <dir> with <old>
# replaced by <new> exactly once. A replacement that changes nothing is reported, so
# a rule is never judged against a copy that still has the control in it.
sabotage() {
	rm -rf "$4"; mkdir -p "$4"; cp "$HERE"/.github/workflows/*.yml "$4/"
	python3 - "$4/$1" "$2" "$3" <<'PY' || echo "SABOTAGE INERT"
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(f"{old!r} occurs {text.count(old)} times in {path}")
open(path, "w").write(text.replace(old, new))
PY
}
