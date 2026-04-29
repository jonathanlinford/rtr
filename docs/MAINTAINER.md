# Maintainer notes

## Branch protection

You want `main` to be the only place releases happen, with no direct
pushes — only PRs that pass CI, and only you can merge them.

The fastest way is the GitHub CLI. After the repo is on GitHub:

```sh
# Replace OWNER/REPO with your actual repo, e.g. jonny/rtr.
REPO=OWNER/REPO

gh api -X PUT "repos/$REPO/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  -f required_status_checks.strict=true \
  -f 'required_status_checks.contexts[]=swift test' \
  -F enforce_admins=false \
  -F required_pull_request_reviews.required_approving_review_count=0 \
  -F required_pull_request_reviews.require_code_owner_reviews=false \
  -F restrictions=null \
  -F allow_force_pushes=false \
  -F allow_deletions=false \
  -F required_linear_history=true \
  -F required_conversation_resolution=true
```

Notes:

- `required_status_checks.contexts` must match the **job name** exactly.
  Our test workflow's job is named `swift test` (see
  `.github/workflows/test.yml`). If you rename the job, update this here.
- `enforce_admins=false` means you can still bypass protection in a true
  emergency (the repo owner is the only admin). Set it to `true` if you
  want to bind your own hands too.
- `required_approving_review_count=0` means PRs don't need anyone *else*
  to approve — appropriate for a solo project. The protection still blocks
  direct pushes and forces all changes to go through PRs.

### Locking down who can push at all

For a personal repo on a personal account, you're already the only one
who can write to the repo. If this is a GitHub organization repo and you
want to lock things further:

1. **Settings → Collaborators** — only you (and any explicit collaborators
   you grant write access).
2. **Settings → Branches → Branch protection rule for `main`** — set
   "Restrict who can push to matching branches" and add only your user.
3. **Settings → Actions → General → Workflow permissions** — set to
   *Read and write permissions* only if needed (the release workflow
   needs write access to create releases).

### Tag protection

Releases fire on `v*` tag pushes. To make sure only you can push tags:

```sh
gh api -X POST "repos/$REPO/tags/protection" \
  -f pattern="v*"
```

(Tag protection is currently *all collaborators with write*, so on a solo
repo this is implicit.)

## Cutting a release

```sh
git tag v0.1.0
git push origin v0.1.0
```

The `release.yml` workflow builds `rtr.app`, zips it, and creates a
GitHub Release with auto-generated notes attached. `workflow_dispatch`
also works if you want to test the build flow without tagging.

## Distribution caveats

The release zip is **ad-hoc signed** (`codesign --sign -`). When a user
downloads it, macOS Gatekeeper will refuse to launch it on first open.
They'll need to right-click → Open, or run:

```sh
xattr -dr com.apple.quarantine /path/to/rtr.app
```

For a smoother experience you'd need a Developer ID certificate ($99/yr
Apple Developer Program) and notarization. See **Distribution options**
in the project README's parent doc, or the section below for a quick
overview.

## Distribution options (summary)

1. **GitHub Releases (current)** — free, works for technical users,
   requires the quarantine workaround on first launch.
2. **Developer ID + notarization** — $99/yr, lets users double-click the
   download and have it just work. Add notarization to the release
   workflow with `notarytool`.
3. **Homebrew tap** — `brew install --cask jonny/tap/rtr`. Trivial to set
   up once binaries are downloadable from GitHub Releases.
4. **Mac App Store** — most friction for you (entitlements, sandboxing,
   review), but lowest friction for users. Probably overkill for a
   default-browser tool that needs Apple Events / LaunchServices access
   the App Store sandbox restricts.
