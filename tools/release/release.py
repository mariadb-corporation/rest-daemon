#!/usr/bin/env python3
# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 USA

# The deterministic half of the /release command (.claude/commands/release.md):
# every check the release procedure makes against GitHub, and the waiting it
# does on workflow runs. The procedure itself -- what to do with each answer --
# lives in the command. A port of MariaDB Shell's scripts/release.py, without
# its plugins repo and sandbox servers.
#
# Subcommands:
#   preflight            VERSION on main and release/candidate, the last
#                        release and the release/candidate branch, with the
#                        decision each one leads to.
#   bump-pr V            Opens the PR that sets VERSION on main to V (or finds
#                        the one already open).
#   push-rc SHA          Fast-forwards release/candidate to SHA.
#   find-run             Waits for a workflow run matching some filters to
#                        appear, and prints its id.
#   approve-build RUN_ID Approves the release-build environment review that
#                        holds a Rest-Daemon-Release run, once the run is
#                        waiting for it.
#   watch RUN_ID         Polls a run until it finishes, reporting every job as
#                        it starts and ends, and stops at the first failed job.
#
# Needs the GitHub CLI (gh), logged in with access to the repository.

import argparse
import base64
import datetime
import json
import re
import subprocess
import sys
import time

REPO = "mariadb-corporation/rest-daemon"
RC_BRANCH = "release/candidate"
VERSION_FILE = "VERSION"

# The environment rest-daemon-release.yml's first job runs in. Its required
# reviewers hold every build until one of them approves it.
BUILD_ENVIRONMENT = "release-build"

VERSION_PATTERN = re.compile(r"^(\d{2})\.(\d{1,2})\.(\d+)$")
VERSION_LINE = re.compile(r"^(VERSION[ \t]*=[ \t]*)(\S*)(.*)$", re.MULTILINE)


def run(command, check=True, stdin=None):
    try:
        result = subprocess.run(command, capture_output=True, text=True, input=stdin)
    except FileNotFoundError:
        raise SystemExit(f"'{command[0]}' is needed but was not found.")
    if check and result.returncode != 0:
        raise SystemExit(f"{' '.join(command)} failed:\n{result.stderr.strip()}")
    return result


def gh(*args, check=True):
    return run(["gh", *args], check=check).stdout


def gh_json(*args):
    return json.loads(gh(*args))


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc)


def stamp():
    return now_utc().strftime("%H:%M:%S")


def parse_time(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

def version_tuple(version):
    match = VERSION_PATTERN.match(version)
    return tuple(int(part) for part in match.groups()) if match else None


def raw_file(path, ref):
    return gh("api", f"repos/{REPO}/contents/{path}?ref={ref}", "-H", "Accept: application/vnd.github.raw")


def restd_version(ref):
    """The version on a ref, read the way CMakeLists.txt and publish-release
    read it: the VERSION = <value> entry of the VERSION file."""
    match = VERSION_LINE.search(raw_file(VERSION_FILE, ref))
    return match.group(2) if match else None


def last_release():
    """The newest published release (prereleases count, drafts do not)."""
    releases = gh_json(
        "release", "list", "-R", REPO, "--exclude-drafts", "--limit", "50",
        "--json", "tagName,isPrerelease,publishedAt",
    )
    best = None
    for release in releases:
        version = version_tuple(release["tagName"].lstrip("v"))
        if version and (best is None or version > best[0]):
            best = (version, release)
    if best is None:
        return None
    release = best[1]
    return {
        "tag": release["tagName"],
        "version": release["tagName"].lstrip("v"),
        "prerelease": release["isPrerelease"],
        "published_at": release["publishedAt"],
    }


def expected_next_version(last, today):
    """yy.mm.p: p counts the releases of the month, from 0.

    The month is written without a leading zero, as every release tag so far
    writes it (26.10.0, 26.10.1).
    """
    yy, mm = today.year % 100, today.month
    if last is not None:
        last_yy, last_mm, last_p = version_tuple(last["version"])
        if (last_yy, last_mm) == (yy, mm):
            return f"{yy}.{mm}.{last_p + 1}"
    return f"{yy}.{mm}.0"


def check_version(main_version, last, today):
    """Decides whether main's version can be this release's version.

    Being newer than the last release is not enough: the version also has to
    be in the current month. 26.10.3 on main is newer than a released 26.10.2,
    but on 2026-11-01 the release is 26.11.0 and main still needs a bump.

    Returns release_version, the version this release goes out as: main's when
    it is bumped, expected_next when it is not.
    """
    notes = []
    expected = expected_next_version(last, today)
    main = version_tuple(main_version or "")
    if main is None:
        return {"bumped": False, "expected_next": expected, "release_version": expected,
                "notes": [f"main's version '{main_version}' is not yy.mm.p"]}

    last_version = version_tuple(last["version"]) if last else None
    current_month = (today.year % 100, today.month)
    if last_version is not None and main <= last_version:
        bumped = False
        notes.append(f"main's {main_version} is not newer than the last release {last['version']}")
    elif main[:2] < current_month:
        bumped = False
        notes.append(f"main's {main_version} is newer than the last release, but from an earlier month "
                     f"than today's {today.isoformat()}")
    else:
        bumped = True
        if main_version != expected:
            # Newer and not from a past month, but not the version this
            # procedure would have picked: a skipped patch number, or a month
            # still to come.
            notes.append(f"newer than the last release, but the next version by yy.mm.p would be {expected}")
    return {"bumped": bumped, "expected_next": expected,
            "release_version": main_version if bumped else expected, "notes": notes}


# ---------------------------------------------------------------------------
# Branches
# ---------------------------------------------------------------------------

def branch_sha(branch):
    return gh("api", f"repos/{REPO}/git/ref/heads/{branch}", "--jq", ".object.sha").strip()


def rc_state():
    """Where release/candidate stands against main: identical, behind (can be
    fast-forwarded to main) or diverged/ahead (cannot)."""
    main_sha = branch_sha("main")
    rc_sha = branch_sha(RC_BRANCH)
    # compare/BASE...HEAD: status is HEAD relative to BASE, so "ahead" means
    # main is ahead of release/candidate -- a fast-forward.
    compare = gh_json("api", f"repos/{REPO}/compare/{rc_sha}...{main_sha}")
    status = compare["status"]
    meaning = {"identical": "identical", "ahead": "behind main (fast-forward)"}.get(status, status)
    return {"main_sha": main_sha, "rc_sha": rc_sha, "rc_vs_main": meaning,
            "rc_only_commits": compare.get("behind_by", 0),
            "can_fast_forward": status in ("identical", "ahead")}


# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

def cmd_preflight(args):
    today = now_utc().date()
    state = rc_state()
    state["main_version"] = restd_version(state["main_sha"])
    state["rc_version"] = restd_version(state["rc_sha"])
    last = last_release()
    version_check = check_version(state["main_version"], last, today)
    release_tag = f"v{version_check['release_version']}"
    existing = gh_json("release", "list", "-R", REPO, "--limit", "50", "--json", "tagName,isDraft,isPrerelease")
    existing = next((r for r in existing if r["tagName"] == release_tag), None)

    report = {
        "today": today.isoformat(),
        "last_release": last,
        "repo": state,
        "step1_version": version_check,
        "release_tag": release_tag,
        "release_exists": existing,
    }

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    def short(sha):
        return sha[:9]

    print("Step 1 - version")
    print(f"  last published version:   "
          f"{last['version'] + (' (pre-release)' if last['prerelease'] else '') if last else 'none'}")
    print(f"  main VERSION:             {state['main_version']}  -> "
          f"{'bumped' if version_check['bumped'] else 'NOT bumped'} (today {today.isoformat()})")
    print(f"  version for this release: {version_check['release_version']}"
          f"{'' if version_check['bumped'] else '  (main needs a bump PR to it)'}")
    for note in version_check["notes"]:
        print(f"  note: {note}")
    if existing:
        print(f"  note: release {release_tag} already exists"
              f"{' (draft)' if existing['isDraft'] else ''}; publishing would update it")
    print()
    print("Step 2 - release/candidate")
    print(f"  main {short(state['main_sha'])} ({state['main_version']}), "
          f"rc {short(state['rc_sha'])} ({state['rc_version']}): rc is {state['rc_vs_main']}"
          + (f", {state['rc_only_commits']} commit(s) only on rc" if not state["can_fast_forward"] else ""))
    return 0


# ---------------------------------------------------------------------------
# bump-pr
# ---------------------------------------------------------------------------

def cmd_bump_pr(args):
    """Opens the PR that sets VERSION on main to a version, or finds the one a
    previous attempt opened. Done through the API, so no checkout is touched."""
    if VERSION_PATTERN.match(args.version) is None:
        raise SystemExit(f"'{args.version}' is not yy.mm.p")
    branch = f"wip/version-{args.version}"

    existing = gh_json("pr", "list", "-R", REPO, "--head", branch, "--state", "open",
                       "--json", "number,url")
    if existing:
        print(f"{existing[0]['number']}\t{existing[0]['url']}\t(already open)")
        return 0

    main_sha = branch_sha("main")
    old = raw_file(VERSION_FILE, main_sha)
    new = VERSION_LINE.sub(lambda m: f"{m.group(1)}{args.version}{m.group(3)}", old, count=1)
    if new == old:
        raise SystemExit(f"{VERSION_FILE} on main already says {args.version}, or has no VERSION = entry")

    blob = gh("api", f"repos/{REPO}/contents/{VERSION_FILE}?ref={main_sha}", "--jq", ".sha").strip()
    gh("api", f"repos/{REPO}/git/refs", "-f", f"ref=refs/heads/{branch}", "-f", f"sha={main_sha}")
    payload = {
        "message": f"Version {args.version}",
        "content": base64.b64encode(new.encode()).decode(),
        "sha": blob,
        "branch": branch,
    }
    run(["gh", "api", "-X", "PUT", f"repos/{REPO}/contents/{VERSION_FILE}", "--input", "-"],
        stdin=json.dumps(payload))

    url = gh("pr", "create", "-R", REPO, "--base", "main", "--head", branch,
             "--title", f"Version {args.version}",
             "--body", f"Sets VERSION to {args.version} for the next release "
                       f"(last release: {args.last or 'none'}).").strip()
    print(f"{url.rstrip('/').rpartition('/')[2]}\t{url}\t(created)")
    return 0


# ---------------------------------------------------------------------------
# push-rc
# ---------------------------------------------------------------------------

def cmd_push_rc(args):
    """Fast-forwards release/candidate to a SHA. force=false: GitHub refuses
    anything but a fast-forward, and so does the branch's ruleset."""
    gh("api", "-X", "PATCH", f"repos/{REPO}/git/refs/heads/{RC_BRANCH}",
       "-f", f"sha={args.sha}", "-F", "force=false")
    print(f"{REPO} {RC_BRANCH} -> {args.sha}")
    return 0


# ---------------------------------------------------------------------------
# find-run
# ---------------------------------------------------------------------------

def cmd_find_run(args):
    """Waits for a run to appear. A run is only listed once GitHub has queued
    it, which for workflow_run- and dispatch-triggered runs can take a while."""
    after = parse_time(args.created_after) if args.created_after else None
    deadline = time.monotonic() + args.timeout
    while True:
        runs = gh_json("run", "list", "-R", REPO, "--workflow", args.workflow, "--limit", "30",
                       "--json", "databaseId,displayTitle,event,headSha,headBranch,createdAt,status,conclusion,url,workflowName")
        matches = [
            r for r in runs
            if (args.event is None or r["event"] == args.event)
            and (args.sha is None or r["headSha"] == args.sha)
            and (args.title is None or r["displayTitle"] == args.title)
            and (after is None or parse_time(r["createdAt"]) >= after)
        ]
        if matches:
            # gh lists newest first; with several matches, report them all so
            # duplicates (a second trigger of the same build) are visible.
            for r in matches:
                print(f"{r['workflowName']} run {r['databaseId']}\t{r['event']}\t{r['headBranch']}\t"
                      f"{r['status']}/{r['conclusion'] or '-'}\t{r['createdAt']}\t{r['url']}")
            return 0
        if time.monotonic() >= deadline:
            print(f"No {args.workflow} run matched within {args.timeout}s.", file=sys.stderr)
            return 1
        time.sleep(args.interval)


# ---------------------------------------------------------------------------
# approve-build
# ---------------------------------------------------------------------------

def cmd_approve_build(args):
    """The build's first job runs in the release-build environment, whose
    required reviewers hold the run in `waiting` until one of them approves.
    Run by a reviewer, this approves it; run by anyone else, it says who can.
    The run only shows the pending review once GitHub has queued the job, so
    wait for it rather than fail on the first look."""
    deadline = time.monotonic() + args.timeout
    while True:
        info = gh_json("run", "view", str(args.run_id), "-R", REPO,
                       "--json", "status,conclusion,url,workflowName")
        name = f"{info['workflowName']} run {args.run_id}"
        pending = gh_json("api", f"repos/{REPO}/actions/runs/{args.run_id}/pending_deployments")
        ours = [d for d in pending if d["environment"]["name"] == BUILD_ENVIRONMENT]
        if ours:
            review = ours[0]
            if not review["current_user_can_approve"]:
                reviewers = ", ".join(
                    r["reviewer"].get("slug") or r["reviewer"].get("login") for r in review["reviewers"])
                print(f"{name} is waiting for the {BUILD_ENVIRONMENT} review, which you cannot approve.\n"
                      f"Ask one of: {reviewers}\n{info['url']}", file=sys.stderr)
                return 1
            run(["gh", "api", "-X", "POST", f"repos/{REPO}/actions/runs/{args.run_id}/pending_deployments",
                 "--input", "-"],
                stdin=json.dumps({"environment_ids": [review["environment"]["id"]],
                                  "state": "approved", "comment": "/release"}))
            print(f"[{stamp()}] approved the {BUILD_ENVIRONMENT} review of {name}", flush=True)
            return 0
        if info["status"] not in ("queued", "waiting", "pending"):
            # Past the gate already (approved by hand), or finished: nothing
            # to approve.
            print(f"{name} is {info['status']}/{info['conclusion'] or '-'}: no {BUILD_ENVIRONMENT} review pending.",
                  flush=True)
            return 0
        if time.monotonic() >= deadline:
            print(f"{name} showed no {BUILD_ENVIRONMENT} review within {args.timeout}s.", file=sys.stderr)
            return 1
        time.sleep(args.interval)


# ---------------------------------------------------------------------------
# watch
# ---------------------------------------------------------------------------

def cmd_watch(args):
    seen = {}
    name = None
    print(f"[{stamp()}] watching run {args.run_id}", flush=True)
    while True:
        result = run(["gh", "run", "view", str(args.run_id), "-R", REPO,
                      "--json", "status,conclusion,jobs,url,displayTitle,workflowName"], check=False)
        if result.returncode != 0:
            # A transient API error must not end the watch: report and retry.
            print(f"[{stamp()}] gh run view failed, retrying: {result.stderr.strip()}", flush=True)
            time.sleep(args.interval)
            continue
        run_info = json.loads(result.stdout)
        if name is None:
            name = f"{run_info['workflowName']} run {args.run_id}"
            print(f"[{stamp()}] {name}: {run_info['displayTitle']}\n           {run_info['url']}", flush=True)

        failed = []
        for job in run_info["jobs"]:
            state = job["conclusion"] or job["status"]
            if seen.get(job["name"]) != state:
                seen[job["name"]] = state
                print(f"[{stamp()}] {job['name']}: {state}", flush=True)
            if job["conclusion"] in ("failure", "timed_out", "startup_failure"):
                failed.append(job)

        if failed and not args.keep_going and run_info["status"] != "completed":
            report_failures(args, failed)
            print(f"[{stamp()}] RESULT: {name} failure (still {run_info['status']}; "
                  "not cancelled)", flush=True)
            return 1

        if run_info["status"] == "completed":
            conclusion = run_info["conclusion"]
            if failed:
                report_failures(args, failed)
            print(f"[{stamp()}] RESULT: {name} {conclusion}", flush=True)
            return 0 if conclusion == "success" else 1
        time.sleep(args.interval)


def report_failures(args, failed):
    for job in failed:
        print(f"\n=== FAILED: {job['name']} ({job['conclusion']})\n    {job['url']}", flush=True)
        failed_steps = [s["name"] for s in job.get("steps", []) if s.get("conclusion") == "failure"]
        if failed_steps:
            print(f"    failed step: {', '.join(failed_steps)}", flush=True)
        log = run(["gh", "run", "view", "-R", REPO, "--job", str(job["databaseId"]), "--log-failed"],
                  check=False)
        # Each line is "<job>\t<step>\t<timestamp> <text>": keep only the text.
        lines = [line.split("\t", 2)[-1].split(" ", 1)[-1] for line in log.stdout.splitlines()]
        # The end of a failed step's log is the runner's post-job cleanup, so
        # show the lines leading up to the first error instead, when there is one.
        first_error = next((i for i, line in enumerate(lines) if line.startswith("##[error]")), None)
        if first_error is not None:
            excerpt = lines[max(0, first_error - args.log_lines + 1):first_error + 1]
        else:
            excerpt = lines[-args.log_lines:]
        if excerpt:
            print("    --- failed step's log, up to its first error ---", flush=True)
            for line in excerpt:
                print(f"    {line}", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Release checks and run watching for /release.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("preflight", help="Report the state every release step depends on.")
    p.add_argument("--json", action="store_true", help="Print the report as JSON.")
    p.set_defaults(func=cmd_preflight)

    p = sub.add_parser("bump-pr", help="Open (or find) the PR setting VERSION on main.")
    p.add_argument("version", help="The new version, yy.mm.p.")
    p.add_argument("--last", help="The last released version, for the PR description.")
    p.set_defaults(func=cmd_bump_pr)

    p = sub.add_parser("push-rc", help="Fast-forward release/candidate to a main commit.")
    p.add_argument("sha", help="The exact main commit preflight reported.")
    p.set_defaults(func=cmd_push_rc)

    p = sub.add_parser("find-run", help="Wait for a matching workflow run and print it.")
    p.add_argument("--workflow", required=True, help="Workflow file name, e.g. rest-daemon-release.yml.")
    p.add_argument("--event", help="push, workflow_run, workflow_dispatch...")
    p.add_argument("--sha", help="Head commit of the run.")
    p.add_argument("--title", help="Exact run display title.")
    p.add_argument("--created-after", help="ISO-8601 UTC time; older runs are ignored.")
    p.add_argument("--timeout", type=int, default=900, help="Seconds to wait (default 900).")
    p.add_argument("--interval", type=int, default=20)
    p.set_defaults(func=cmd_find_run)

    p = sub.add_parser("approve-build", help="Approve the release-build environment review holding a build run.")
    p.add_argument("run_id", type=int)
    p.add_argument("--timeout", type=int, default=300, help="Seconds to wait for the review to appear (default 300).")
    p.add_argument("--interval", type=int, default=15)
    p.set_defaults(func=cmd_approve_build)

    p = sub.add_parser("watch", help="Poll a run until it finishes or a job fails.")
    p.add_argument("run_id", type=int)
    p.add_argument("--interval", type=int, default=60, help="Seconds between polls (default 60).")
    p.add_argument("--keep-going", action="store_true",
                   help="Do not stop at the first failed job; wait for the whole run.")
    p.add_argument("--log-lines", type=int, default=40)
    p.set_defaults(func=cmd_watch)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
