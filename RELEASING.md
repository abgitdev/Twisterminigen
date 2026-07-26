# Source-only release process

Twisterminigen is published as source code. GitHub releases contain only the automatic source
archives generated from the release tag. Do not upload a `.app`, DMG, PKG, model weight, test
artifact, or local project archive.

This process does not require Apple Developer Program membership, a Developer ID certificate, or
notarization. A future public-binary distribution would require a separate design and security
review.

## Release boundary

The public source tree may contain reviewed project source, first-party resources, package locks,
the code license, model-license boundary, notices, and public documentation.

It must not contain credentials, signing material, model weights, user data, application logs,
caches, workstation paths, local agent state, private working notes, test evidence, upstream
research copies, or generated build products.

The first public branch must start from one sanitized root commit. Do not push the private
development branch and do not rewrite it in place.

## 1. Prepare the private worktree

Finish the functional, storage-safety, privacy, and resource tests in the development checkout.
The exporter reads the intended current worktree, so the private branch does not need to be
committed or rewritten merely to publish it. Review its changes and reject whitespace errors:

```bash
git status --short
git diff --check HEAD --
```

Private and ignored files may remain in this checkout. They are not copied by the positive
allowlist. Do not add a GitHub remote here.

## 2. Create an isolated public repository

Export only approved files from the current worktree into an absent destination. The exporter
rejects symlinks, unexpected source-tree files, oversized files, secrets, workstation paths,
assistant-session artifacts, encoded leaks, and archive/container payloads before copying bytes.
It copies no `.git`, source xattrs, resource forks, research, evidence, logs, or cache directories.
macOS may attach its generic `com.apple.provenance` marker to newly created files; the exporter
allows only that OS marker, and Git does not store extended attributes:

```bash
PRIVATE_WORKTREE="$PWD"
EXPORT_PARENT="$(mktemp -d /private/tmp/twisterminigen-public.XXXXXX)"
PUBLIC_CANDIDATE="$EXPORT_PARENT/Twisterminigen"
python3 tools/export_public_source.py \
  --root "$PRIVATE_WORKTREE" \
  --destination "$PUBLIC_CANDIDATE"
cd "$PUBLIC_CANDIDATE"

test ! -e .git
git init --template= -b main
git config user.name "abgitdev"
git config user.email "266600699+abgitdev@users.noreply.github.com"
git config commit.gpgsign false
git config tag.gpgsign false
git config core.hooksPath .git/no-hooks
mkdir "$PWD/.git/no-hooks"
git add -A
PUBLIC_COMMIT_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
GIT_AUTHOR_DATE="$PUBLIC_COMMIT_DATE" \
GIT_COMMITTER_DATE="$PUBLIC_COMMIT_DATE" \
git commit --no-gpg-sign -m "Initial public source release"
```

The public commit must use that GitHub noreply identity for both author and committer. Never add a
co-author trailer containing a private or workstation email. UTC author/committer dates prevent
the commit object from exposing the workstation timezone; the gate requires UTC on every public
commit.

Run the complete source-only gate:

```bash
tools/source_release_gate.sh
```

The gate fails unless:

- the working tree is clean;
- every non-ignored file is committed;
- every tracked path belongs to the exact public allowlist;
- `HEAD` is the only reachable commit for the first upload;
- author and committer use the public identity;
- all tracked entries are regular files, with no symlink or submodule;
- every reachable path and blob passes the privacy, credential, size, and artifact policy; and
- refs and tag metadata are public and resolve to `HEAD`; and
- no deleted history, dangling object, archive, or encoded payload reintroduces private material.

Do not bypass a finding with `git add -f`. Fix the publish tree and rerun the gate.

## 3. Push only the sanitized branch

Configure the new public GitHub repository as the remote of the isolated candidate, then push only
the reviewed branch:

```bash
git remote add origin https://github.com/abgitdev/Twisterminigen.git
git push --set-upstream origin HEAD:refs/heads/main
```

Never run `git push --mirror`, `git push --all`, or `git push --tags` from the private development
repository. Do not upload the development checkout, `.git` directory, `artifacts` directory, or a
manually created project ZIP.

For later releases, work from the public repository or another clone containing only reviewed
public history. Create later commits with UTC author/committer dates as above. Its history may
contain multiple commits and can be checked with:

```bash
SOURCE_RELEASE_HISTORY=reviewed-public \
tools/source_release_gate.sh
```

## 4. Create a GitHub source release

Create a lightweight tag from the tested public commit, rerun the gate so the tag ref is checked,
and push that one tag:

```bash
git tag "v1.0" HEAD
tools/source_release_gate.sh
git push origin "v1.0"
```

Create the GitHub release without uploading assets. The expected assets list is empty; GitHub may
display only its automatically generated source `.zip` and `.tar.gz` links.

Release notes must state that the release contains source only, includes no `.app` or model
weights, and preserves the separate code/model license boundary.

## 5. Verify from GitHub

Clone the public branch into another fresh temporary directory and rerun the gate:

```bash
VERIFY_CLONE="$(mktemp -d /tmp/twisterminigen-verify.XXXXXX)"
git clone --branch main --single-branch --no-tags \
  https://github.com/abgitdev/Twisterminigen.git "$VERIFY_CLONE"
cd "$VERIFY_CLONE"
tools/source_release_gate.sh
git rev-list --count HEAD
git log --format='%h %an <%ae> %cn <%ce>'
```

For the first upload, the commit count must be `1`. Verify on GitHub that the release has no
uploaded binary assets. Keep the private development repository and its local references separate
from this public clone.
