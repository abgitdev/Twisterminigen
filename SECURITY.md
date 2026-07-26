# Security policy

## Supported versions

The current public `main` branch and the latest source release receive security fixes. Older
releases are unsupported unless their release notes explicitly say otherwise.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use the repository's
**Security → Report a vulnerability** flow. Repository owners should keep GitHub private
vulnerability reporting enabled.

Include the affected version, build, commit, macOS version, impact, realistic attack scenario, and
minimal reproduction steps. Use synthetic fixtures. Do not submit real credentials, prompts,
images, user files, workstation paths, or another person's data.

No response-time or bounty commitment is currently offered.

## Scope

Examples in scope include:

- unintended deletion or modification of user data or an externally linked model directory;
- credential exposure or secrets in logs, exports, build products, or release history;
- path traversal, symlink races, unsafe archive handling, or malicious model/LoRA inputs;
- unintentional prompt, image, recipe, or local-path disclosure;
- unbounded disk, log, cache, temporary-file, or memory growth;
- denial of service or memory-safety issues reachable through untrusted input; and
- dependency, build, or source-release supply-chain vulnerabilities.

## Release security

Official releases contain source archives only. Twisterminigen does not publish a prebuilt app,
installer, or model weights. Locally built and ad-hoc signed applications are development
artifacts, not notarized public releases. See [RELEASING.md](RELEASING.md).
