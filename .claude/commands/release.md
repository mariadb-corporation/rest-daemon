---
description: Run the mariadb-restd release end to end -- version bump, release/candidate build and verification, publish. Usage: /release [--official] [--dry-run] [--help]
argument-hint: "[--official] [--dry-run] [--help]"
---

# Release Command

Arguments as typed: `$ARGUMENTS`

Takes mariadb-restd from "main is ready" to a published GitHub release of
`mariadb-corporation/rest-daemon`. The same procedure as MariaDB Shell's
`/release`, without its plugins repo, sandbox servers and Docker image.

| Workflow file | Workflow name | Role |
|---|---|---|
| `rest-daemon-release.yml` | Rest-Daemon-Release | builds the five packages, on a push to `release/candidate` (or started by hand); its first job runs in the `release-build` environment, whose required reviewers (the devtools team) hold every build until one of them approves it |
| `verify-packages.yml` | Verify Packages | starts by itself when a build succeeds; tests each package on pristine runners and leaves the `verified-build-<build run>` artifact |
| `publish-release.yml` | Publish Release | started by hand from `main`; refuses a build without that artifact, creates or updates the release `v<VERSION>` |

`tools/release/release.py` does the checks and the waiting: `preflight`,
`bump-pr`, `push-rc`, `find-run`, `approve-build` and `watch`. Run it as
`python3 tools/release/release.py <subcommand>`. Run `--help` on a subcommand
for its flags.

## Arguments

Parse `$ARGUMENTS`:

| Flag | Effect | Default |
|---|---|---|
| `--official` | publish with `prerelease=false` | pre-release (`prerelease=true`) |
| `--dry-run` | publish with `dry_run=true`: assembled and checked, nothing released | off |
| `--help` | print the help below and stop | — |

With `--help`, print the block below exactly as written and stop. Run
nothing, not even `preflight`, and ignore any other flag given with it. If
there is any other unknown argument, stop and print the usage line,
`Usage: /release [--official] [--dry-run] [--help]`. Before step 1, print the
mode in effect, for example: `Mode: pre-release, real publish`.

```
/release [--official] [--dry-run] [--help]

Takes mariadb-restd from "main is ready" to a published GitHub release.

  --official   publish an official release (default: pre-release)
  --dry-run    run everything, but publish-release assembles and checks
               the release without creating it (default: off)
  --help       show this help

Steps, in order. Each one checks first and does only what is missing, so
running /release again resumes where the last run stopped.

  0 Preflight   report the last release, VERSION on main and
                release/candidate, and where release/candidate stands
  1 Version     main's VERSION must be newer than the last published
                version and in the current month (yy.mm.p); otherwise open
                and merge a "Version <v>" PR
  2 Build &     fast-forward release/candidate to main, or reuse an
    verify      existing build; approve the build's release-build
                environment review; wait for Rest-Daemon-Release and
                Verify Packages
  3 Publish     show a pre-publish summary and ask before a real publish;
                run publish-release and report the release

It asks you before: a real publish, a version that skips ahead, a
release/candidate that cannot fast-forward, and a build that main has moved
past.

It changes: a version PR on main, release/candidate (fast-forward only,
never forced), workflow runs (including the environment approval of the
build), and the release itself. It never force-pushes, never merges past a
failing check, and leaves a failed run as it is for you to inspect.

Details: .claude/commands/release.md · helper: tools/release/release.py --help
```

## Rules for the whole run

- **Steps run in strict order.** A step starts only when the step before it
  ended `done` or `skipped`.
- **Report after every step** in this shape, before starting the next one:

  ```
  ── Step N: <name> — <done | skipped | failed | waiting for you>
     Checks:    <each verification made and what it found>
     Decisions: <each choice made and why>
     Actions:   <PRs opened/merged, branches moved, runs started/cancelled, with links>
  ```

  Each step below lists what its report must show, besides that.
- **Name the workflow with every run number**, in reports and the summary
  alike: `Rest-Daemon-Release run 41066725233`, never a bare `run
  41066725233` or `BUILD`. The names are in the table above. `release.py`
  already prints run numbers this way.
- **Every step checks before it acts**, so running `/release` again resumes
  where a previous run stopped. Nothing needs remembering between runs except
  what GitHub already holds.
- **Wait on runs in the background, never with sleep loops.** Start
  `release.py watch <run-id>` (or `gh pr checks … --watch`) with Bash
  `run_in_background: true`. When a watch exits, read its output and report
  it. `watch` prints each job as it starts and finishes. It exits at the
  first failed job and prints that job's failed step and the log leading up
  to its first error.
- **On any failure, stop the release.** Report what failed, with the job, the
  failed step, the error excerpt and the run link, and what to fix. Do not
  cancel the failed run, and do not retry on your own. Tell the user that
  `/release` resumes once it is fixed.
- **Never force anything.** No force-push, no `--admin` merges, no merging
  past a failing check, no `git push --force` to release/candidate. When a
  precondition fails in a way these steps don't cover (a diverged
  release/candidate, an open PR that doesn't match), stop and ask.
- Temporary files go in the session scratchpad, never in the user's checkout.
  The steps work through the GitHub API and need no checkout at all.
- Commits created here carry no `Co-Authored-By` or other attribution
  trailer.
- **Keep a record for the final summary** as you go: every version, tag, run,
  PR, branch move and decision reported along the way.

## Step 0: Preflight

```
python3 tools/release/release.py preflight          # human summary
python3 tools/release/release.py preflight --json   # same data, for decisions
```

Show the summary to the user. It gives the last published version, the
version for this release, VERSION on main and on release/candidate, whether
a release of that version already exists, and where release/candidate stands
against main. Steps 1–2 take their decisions from it.

## Step 1: Version bumped on main

Versions are `yy.mm.p`. The month is written without a leading zero, as every
tag so far writes it (`26.10.0`, `26.10.1`). `p` counts the month's releases
from 0. The last published version is the highest `v<version>` among
published releases, prereleases included.

Main's version is **bumped** only when it is newer than the last published
version **and** is not from an earlier month than today. With 26.10.2
published and 26.10.3 on main, the release is 26.10.3 on 2026-10-19. On
2026-11-01, main needs a bump to 26.11.0. `preflight` applies this rule and
gives `release_version`, the version this release goes out as.

The report must show, on lines of their own:

```
   Last published version:   <last_release.version> (<pre-release|release>, <published_at>)
   Version for this release: <release_version>
```

- `step1_version.bumped` is true: **done**. If it carries a note (main is
  newer, but is not the next `yy.mm.p`, for example it skips a number or is in
  a month still to come), show the note and ask before going on.
- Not bumped: open the bump PR to `release_version`:

  ```
  python3 tools/release/release.py bump-pr <release_version> --last <last_release.version>
  ```

  This creates branch `wip/version-<v>` with a single commit, `Version <v>`,
  which changes only the `VERSION =` line of `VERSION`, and opens the PR
  `Version <v>`. If a previous run already opened that PR, it reuses it.
  1. The repository has no PR checks and needs no approving review, but only
     devtools team members can merge into main. Check anyway, so a check added
     later is not merged past:
     `gh pr checks <N> -R mariadb-corporation/rest-daemon --watch --fail-fast --interval 30`
     (it says there are no checks when there are none; that is not a failure).
  2. Merge it with a merge commit, as the repository's PRs are merged:
     `gh pr merge <N> -R mariadb-corporation/rest-daemon --merge --delete-branch`.
     If the merge is refused because the user may not merge into main, stop
     and report it.
  3. Re-run `preflight` and confirm that main now has `<v>`. Nothing runs on
     a push to main, so there is nothing to wait for.

## Step 2: Build and verify on release/candidate

From a fresh `preflight`:

1. **Require the version**: `repo.main_version` must be `release_version`.
2. **Require a fast-forward**: `repo.can_fast_forward` must be true. If
   release/candidate has diverged from main, stop and ask, showing the
   commits only on it:
   `gh api repos/mariadb-corporation/rest-daemon/compare/main...release/candidate --jq '.commits[] | "\(.sha[0:9]) \(.commit.message | split("\n")[0])"'`.
   Never force it. A ruleset on release/candidate refuses any update that is
   not a fast-forward, and lets only repository admins update it at all.
3. **Reuse a build that already exists.** If release/candidate is
   `identical` to main, list the Rest-Daemon-Release runs for
   `repo.main_sha`
   (`find-run --workflow rest-daemon-release.yml --sha <sha> --timeout 0`).
   Take the newest one.
   - If it succeeded, use it as `BUILD` and go to 6.
   - If it is still running, or waiting for its environment review, approve
     it as in 5 and watch it.
   - If there is none, or only failed ones, start a build without moving the
     branch. Note the time, then
     `gh workflow run rest-daemon-release.yml -R mariadb-corporation/rest-daemon --ref release/candidate`,
     find the run with
     `find-run --workflow rest-daemon-release.yml --event workflow_dispatch --sha <sha> --created-after <time>`,
     and go to 5.
4. **Move release/candidate.** Note the time, then fast-forward it to the
   exact SHA `preflight` reported. If main moved since, re-run `preflight`
   first.

   ```
   python3 tools/release/release.py push-rc <repo.main_sha>
   ```

   The push starts the build. Find it with
   `find-run --workflow rest-daemon-release.yml --event push --sha <sha> --created-after <time>`.
   If push-rc is refused because the user may not update release/candidate
   (only admins can), stop and report it.
5. **Approve the build.** The build's first job (Approval) runs in the
   `release-build` environment, whose required reviewers hold the run in
   `waiting` until one of them approves it. Approve it before watching:

   ```
   python3 tools/release/release.py approve-build <BUILD>
   ```

   It waits for the review to appear, approves it, and prints that it did.
   If the user running `/release` is not a reviewer, it exits 1 and names who
   is: report that, give the run link, and wait for the approval (`watch`
   keeps polling meanwhile; a run left unapproved for 30 days fails). If it
   reports no review pending, the run is already past the gate: say so and
   go on.

   Watch `BUILD`. It takes about 45 minutes, longer when the JIT executor
   library cache misses.
6. **Verification.** Verify Packages starts by itself when the build
   finishes. Find its run with
   `find-run --workflow verify-packages.yml --title "Verify build <BUILD>" --timeout 900`.
   If no run appears, start it by hand with
   `gh workflow run verify-packages.yml -R mariadb-corporation/rest-daemon --ref main -f run_id=<BUILD>`.
   Watch it. Success alone is not enough: confirm that the run carries the
   artifact publish-release gates on:

   ```
   gh api repos/mariadb-corporation/rest-daemon/actions/runs/<VERIFY>/artifacts --jq '.artifacts[].name' | grep -x "verified-build-<BUILD>"
   ```

The report must show release/candidate as `<old sha> → <new sha>` (or
`unchanged`), the build and verification runs with their workflow names, who
approved the build's environment review (`/release`, or a reviewer by hand),
and the marker artifact.

## Step 3: Publish

1. Check whether `gh release view v<v> -R mariadb-corporation/rest-daemon`
   already finds a published release. publish-release would update it,
   replacing its assets.
2. **Check that main has not moved past the build.** A build takes most of an
   hour, and PRs keep merging meanwhile. Re-run `preflight` and compare
   `repo.main_sha` against the build's `headSha`
   (`gh run view <BUILD> -R mariadb-corporation/rest-daemon --json headSha`).
   If main moved, list the commits the build does not have, with their PR
   numbers, from
   `gh api repos/mariadb-corporation/rest-daemon/compare/<built sha>...<main sha> --jq '.commits[] | "\(.sha[0:9]) \(.commit.message | split("\n")[0])"'`.
   Also note whether VERSION on main changed. That is a warning, not a
   failure: the build is still valid, it just doesn't have those commits.
3. **A real publish needs the user's confirmation; a dry run does not.**
   Without `--dry-run`, first show a **pre-publish summary**. It is the final
   summary table, filled in from steps 1–2, with the Publish row holding what
   is about to be sent:
   - the exact `gh workflow run publish-release.yml …` inputs: `run_id`,
     `prerelease`, `dry_run=false` (`tag` is left blank, so it is
     `v<VERSION>` at the build's commit);
   - the release it creates: tag `v<v>`, title `mariadb-restd <v>`,
     pre-release or official, at the Rest-Daemon-Release run's commit, with
     the five packages and `SHA256SUMS`;
   - for an official release: it becomes `/releases/latest/`, which is what
     `install.sh` and `install.ps1` install by default;
   - anything unusual seen along the way, each on its own line: a version
     note from step 1, a cancelled run, a release `v<v>` that already exists
     (it would be updated), artifacts that expire within 7 days (the
     packages are run artifacts of the build), or **main moved past the
     build** (from 2), with the list of commits the release would not
     include.

   Then ask with AskUserQuestion. Give two options: **Publish v<v>**, naming
   pre-release or official, and **Stop**, which publishes nothing. When main
   moved past the build, add a third option between them: **Rebuild with the
   latest main**. It goes back to step 2: fast-forward release/candidate to
   the new main, build, verify, then show this summary again. If main's
   version changed, it goes back to step 1 instead. Do not dispatch anything
   until the answer is *Publish*. On *Stop*, end with the summary, state that
   nothing was published, and say that `/release` picks up here again
   because every earlier step is already done.

   With `--dry-run` there is no question, but a main that moved past the
   build is still reported, with its commits, in the step report and the
   final summary.
4. Note the time and dispatch:

   ```
   gh workflow run publish-release.yml -R mariadb-corporation/rest-daemon --ref main \
       -f run_id=<BUILD> -f prerelease=<true unless --official> -f dry_run=<true if --dry-run>
   ```

   Report the inputs given. For a real publish they must be exactly the ones
   the user confirmed. If anything changed since, for example main moved or
   a newer build appeared, show the pre-publish summary again and ask again.
5. Find the run. Its title is `Publish (version from build) from run <BUILD>`,
   or `Dry run (version from build) from run <BUILD>` for a dry run:

   ```
   find-run --workflow publish-release.yml --event workflow_dispatch --title "<title>" --created-after <time>
   ```

   Then watch it. Report every `::warning::` in its log.
6. Report the result:
   - **Real publish:** `gh release view v<v> -R mariadb-corporation/rest-daemon --json url,isPrerelease,assets`,
     giving the URL, the pre-release flag and the asset count (six: five
     packages and `SHA256SUMS`).
   - **Dry run:** the `dry-run-assets-<BUILD>` artifact on the run. State
     plainly that nothing was published. Running `/release` again without
     `--dry-run` publishes the same build, because every earlier step is
     `skipped` or reused.

## Final summary

End with one table that holds everything the steps reported, so it can be
read on its own. Use one row per item, and `—` when a step had nothing to do:

| Item | What to put |
|---|---|
| Mode | pre-release or official; dry run or real publish |
| Last published version | version, pre-release or not, date |
| Version for this release | the version, and whether main had to be bumped |
| Version bump | the PR (number, link) and its merge, or "already bumped" |
| release/candidate | old → new SHA, or unchanged |
| Build | Rest-Daemon-Release run, link, whether it was reused or new, and its environment approval (`/release`, by hand, or not needed) |
| Verification | Verify Packages run, link, marker artifact |
| Publish | Publish Release run, link, the inputs given (prerelease, dry_run); for a real publish, the user's confirmation |
| Result | release URL, pre-release flag and asset count, or "dry run, nothing published" with the assets artifact |
| Deadlines | when the build's artifacts expire, when relevant |
| Runs cancelled | any, with the reason |
