## Summary

<!-- What does this PR do? 1-3 bullet points. -->

## Changes

<!-- List the main changes made. -->

## Test plan

<!-- How was this tested? Check all that apply. -->

- [ ] `python3 -m venv /tmp/podman-mldsa && /tmp/podman-mldsa/bin/python -m pip install --quiet --require-hashes --only-binary=:all: -r .github/scripts/release/sign-requirements.txt` was run once, for the ML-DSA-65 suite
- [ ] `status=0; for t in $(find tests -name '*.test.sh' | sort); do case "$t" in *-mldsa.test.sh) PATH="/tmp/podman-mldsa/bin:$PATH" bash "$t" ;; *) bash "$t" ;; esac </dev/null || { echo "FAILED $t"; status=1; }; done; [ "$status" -eq 0 ]` passes locally (the tools it needs are listed in CONTRIBUTING.md)
- [ ] `find scripts tests -name '*.sh' -print0 | xargs -0 shellcheck -S warning` is clean (shellcheck v0.11.0, the version CI pins)
- [ ] For changes to the build, the package was built and installed on Debian 13 and Ubuntu 24.04 and 26.04, and refused on Ubuntu 22.04 and Debian 12

<!--
A test that was not watched fail is not a test. If this PR adds or changes a
check, say which control you removed to make it go red, and what it reported.
-->

- [ ] New or changed checks were verified by deleting the control and watching them fail

## Checklist

- [ ] Targets `main` (this repository has no `develop` branch)
- [ ] Commits are signed off (DCO, `git commit -s`)
- [ ] Labels applied (`type:`, `prio:`, `effort:`, `area:` where applicable)
- [ ] Every script under `scripts/` still has a test (`bash scripts/quality/check-test-coverage.sh`)
- [ ] Every refusal has a mutation entry or an exemption (`bash scripts/quality/check-mutation-coverage.sh`)
- [ ] No folder holds more than twenty files directly (`bash scripts/quality/check-folder-size.sh`)
- [ ] No secrets, keys or credentials in code, logs or fixtures
- [ ] Docs updated if behaviour changed

## Related issues

<!-- Closes #123 -->
