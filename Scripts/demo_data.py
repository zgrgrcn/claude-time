#!/usr/bin/env python3
"""Synthetic Claude Code transcripts for demos, screenshots and manual testing.

Writes OUT_DIR/<project-dir>/<session-id>.jsonl (plus a few subagent transcripts in
<session-id>/subagents/) for six fictional projects, covering the last --days days up to
now: weekday working hours with meetings and lunch, some evenings and weekends, parallel
sessions, and varying numbers of prompts per session.

Claude Time only reads "timestamp", "cwd" and user prompts ("role":"user","content":"...")
from each line; the rest of every record just mimics the shape of real transcripts.
Everything is made up: project names, paths (under a generic "~/"), prompts and output.

Usage: demo_data.py [--days 30] [--seed 7] OUT_DIR
Stdlib only; works with the python3 that ships with the Xcode Command Line Tools.
"""
import argparse
import json
import os
import random
import shutil
import sys
import uuid
from datetime import datetime, timedelta, timezone

MARKER = ".claude-time-demo"  # hidden, so the scanner skips it

PROJECTS = {
    "payments-api": "~/code/payments-api",
    "ios-app": "~/code/ios-app",
    "data-pipeline": "~/code/data-pipeline",
    "infra": "~/code/infra",
    "marketing-site": "~/code/marketing-site",
    "notes": "~/notes",
}

PROMPTS = {
    "payments-api": [
        "Add idempotency keys to POST /refunds",
        "Why does test_partial_capture fail only on CI?",
        "Refactor the webhook retry queue to use exponential backoff",
        "Write a migration that backfills settlement_currency",
        "Review this diff for race conditions in the ledger writer",
        "Add request tracing to the payout worker",
        "Explain how the reconciliation job handles duplicate events",
        "Upgrade the payment provider SDK and fix the breaking changes",
    ],
    "ios-app": [
        "Fix the dark mode contrast on the checkout sheet",
        "Why does the order list jump when it refreshes?",
        "Add snapshot tests for the onboarding screens",
        "Move the settings screen to the new navigation stack",
        "Make the receipt view work with Dynamic Type",
    ],
    "data-pipeline": [
        "The nightly export job ran out of memory, find out why",
        "Add a data quality check for negative amounts",
        "Partition the events table by day",
        "Speed up the dedupe step, it takes 40 minutes",
        "Write a backfill for last week's missing rows",
    ],
    "infra": [
        "Add a staging environment to the deploy workflow",
        "Why is the database CPU at 90% every hour?",
        "Rotate the service certificates before they expire",
        "Tighten the security group rules for the worker nodes",
    ],
    "marketing-site": [
        "Make the pricing table responsive",
        "Add an FAQ section below the hero",
        "Improve the Lighthouse score on the landing page",
        "Fix the broken links in the changelog",
    ],
    "notes": [
        "Summarize this week's meeting notes into action items",
        "Turn these bullet points into a short blog post draft",
        "Organize my reading list by topic",
    ],
}

REPLIES = [
    "I'll start by reading the relevant files.",
    "Found it. The cause is a missing await in the retry path.",
    "Here is the plan: update the handler, add a test, then run the suite.",
    "All tests pass. Summary of the changes below.",
    "That needs a schema change; I'll write the migration first.",
]

TOOLS = [
    ("Read", {"file_path": "src/handlers.ts"}),
    ("Grep", {"pattern": "retry"}),
    ("Edit", {"file_path": "src/queue.ts"}),
    ("Bash", {"command": "make test"}),
    ("Bash", {"command": "git diff --stat"}),
]

WORK_FOCUS = [("payments-api", 0.7), ("data-pipeline", 0.15), ("ios-app", 0.1), ("infra", 0.05)]


def pick(rng, weighted):
    r, acc = rng.random() * sum(w for _, w in weighted), 0.0
    for item, w in weighted:
        acc += w
        if r < acc:
            return item
    return weighted[-1][0]


def mins(m):
    return timedelta(minutes=m)


def iso_utc(t):
    """Local naive datetime -> '2026-09-24T09:14:03.120Z'."""
    u = t.astimezone(timezone.utc)
    return u.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (u.microsecond // 1000)


def encode_dir(cwd):
    """Claude Code names project folders after the working directory, non-alphanumerics -> '-'."""
    return "".join(c if c.isalnum() else "-" for c in cwd)


def day_plan(rng, day, is_today):
    """(project, start, end) work sessions for one calendar day, as local naive datetimes."""
    at = lambda h, m=0: datetime(day.year, day.month, day.day, h, m)
    plans = []
    weekday = day.weekday()
    if weekday < 5:
        if not is_today and rng.random() < 0.06:
            return plans  # a day off
        focus = "payments-api" if is_today else pick(rng, WORK_FOCUS)
        other = pick(rng, [(p, w) for p, w in WORK_FOCUS if p != focus] or WORK_FOCUS)
        # Morning, split by a stand-up or meeting that is longer than the idle threshold.
        start = at(9) + mins(rng.uniform(-20, 35))
        end = at(12) + mins(rng.uniform(0, 45))
        cut = start + (end - start) * rng.uniform(0.35, 0.6)
        plans.append((focus, start, cut))
        plans.append((focus if rng.random() < 0.7 else other, cut + mins(rng.uniform(20, 50)), end))
        # Afternoon after lunch.
        start = at(13, 15) + mins(rng.uniform(0, 40))
        end = at(17, 15) + mins(rng.uniform(0, 70))
        if rng.random() < 0.5:
            cut = start + (end - start) * rng.uniform(0.4, 0.6)
            plans.append((other, start, cut))
            plans.append((focus, cut + mins(rng.uniform(5, 30)), end))
        else:
            plans.append((focus, start, end))
        # Parallel sessions: another project in a second terminal, or a second session in the same one.
        if rng.random() < 0.35:
            side = rng.choice([p for p in ("infra", "data-pipeline", "ios-app") if p != focus])
            s = start + mins(rng.uniform(10, 90))
            plans.append((side, s, s + mins(rng.uniform(20, 60))))
        if rng.random() < 0.2:
            s = start + mins(rng.uniform(0, 60))
            plans.append((focus, s, s + mins(rng.uniform(15, 35))))
        # Some evenings on side projects.
        if weekday < 4 and rng.random() < 0.28:
            s = at(20, 15) + mins(rng.uniform(0, 45))
            plans.append((rng.choice(["marketing-site", "notes", "ios-app"]), s, s + mins(rng.uniform(40, 110))))
    elif rng.random() < (0.5 if weekday == 5 else 0.3):
        s = at(10 if weekday == 5 else 16) + mins(rng.uniform(0, 60))
        plans.append((rng.choice(["notes", "marketing-site"]), s, s + mins(rng.uniform(40, 100))))
    return plans


def conversation(rng, start, end):
    """Event times for one session: a prompt, Claude working for a while, you reading, repeat."""
    events, t = [], start
    while t < end:
        events.append(("prompt", t))
        turn_end = t + timedelta(seconds=rng.uniform(15, 360))
        u = t
        while True:
            u += timedelta(seconds=rng.uniform(2, 40))
            if u > turn_end or u >= end:
                break
            events.append((rng.choice(["text", "tool", "tool"]), u))
        gap = rng.uniform(30, 540)          # reading, testing, thinking
        if rng.random() < 0.07:
            gap = rng.uniform(16 * 60, 45 * 60)  # a break longer than the default idle threshold
        t = u + timedelta(seconds=gap)
    return events


class Transcript:
    def __init__(self, rng, project, session_id, sidechain=False):
        self.rng, self.project, self.cwd = rng, project, PROJECTS[project]
        self.session_id, self.sidechain = session_id, sidechain
        self.lines, self.prev, self.prompts = [], None, 0

    def _add(self, t, kind, message):
        rid = str(uuid.UUID(int=self.rng.getrandbits(128), version=4))
        rec = {"parentUuid": self.prev, "isSidechain": self.sidechain, "userType": "external",
               "cwd": self.cwd, "sessionId": self.session_id, "gitBranch": "main",
               "type": kind, "message": message, "uuid": rid, "timestamp": iso_utc(t)}
        # Compact separators: the scanner matches byte patterns such as "timestamp":"
        self.lines.append(json.dumps(rec, separators=(",", ":"), ensure_ascii=False))
        self.prev = rid

    def prompt(self, t, text):
        self.prompts += 1
        self._add(t, "user", {"role": "user", "content": text})

    def text(self, t):
        self._add(t, "assistant", {"role": "assistant", "content": [
            {"type": "text", "text": self.rng.choice(REPLIES)}]})

    def tool(self, t):
        name, args = self.rng.choice(TOOLS)
        tool_id = "toolu_demo_%012x" % self.rng.getrandbits(48)
        self._add(t, "assistant", {"role": "assistant", "content": [
            {"type": "tool_use", "id": tool_id, "name": name, "input": args}]})
        self._add(t + timedelta(milliseconds=self.rng.randint(80, 900)), "user", {"role": "user", "content": [
            {"tool_use_id": tool_id, "type": "tool_result", "content": "ok"}]})

    def write(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(self.lines) + "\n")


def prepare(out):
    real = os.path.realpath(out)
    claude_home = os.path.realpath(os.path.expanduser("~/.claude"))
    if real == claude_home or real.startswith(claude_home + os.sep):
        sys.exit("refusing to write demo data inside %s" % claude_home)
    if os.path.isdir(real) and os.listdir(real):
        if not os.path.exists(os.path.join(real, MARKER)):
            sys.exit("%s is not empty and wasn't created by this script; pick an empty folder" % real)
        shutil.rmtree(real)  # a previous demo run: regenerate from scratch
    os.makedirs(real, exist_ok=True)
    open(os.path.join(real, MARKER), "w").close()
    return real


def main():
    ap = argparse.ArgumentParser(description="Generate synthetic Claude Code transcripts.")
    ap.add_argument("out", help="output folder (created; must be empty or a previous demo folder)")
    ap.add_argument("--days", type=int, default=30, help="days of history ending today (default 30)")
    ap.add_argument("--seed", type=int, default=7, help="random seed (default 7)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    out = prepare(args.out)
    now = datetime.now().replace(microsecond=0)
    cutoff = now - timedelta(seconds=90)  # keep everything in the past
    today = now.date()

    sessions = []
    for back in range(args.days - 1, -1, -1):
        day = today - timedelta(days=back)
        for project, start, end in day_plan(rng, day, back == 0):
            end = min(end, cutoff)
            if end - start >= timedelta(minutes=3):
                sessions.append((project, start, end))
    if not any(start.date() == today for _, start, _ in sessions):
        # Early in the morning or a day off: add a short session so "Today" isn't empty.
        start = max(datetime(today.year, today.month, today.day), cutoff - mins(95))
        sessions.append(("payments-api", start, cutoff))

    totals = {p: [0, 0] for p in PROJECTS}  # sessions, prompts
    for project, start, end in sessions:
        sid = str(uuid.UUID(int=rng.getrandbits(128), version=4))
        tr = Transcript(rng, project, sid)
        events = conversation(rng, start, end)
        prompts = PROMPTS[project]
        for kind, t in events:
            if kind == "prompt":
                tr.prompt(t, rng.choice(prompts))
            elif kind == "text":
                tr.text(t)
            else:
                tr.tool(t)
        folder = os.path.join(out, encode_dir(PROJECTS[project]))
        tr.write(os.path.join(folder, sid + ".jsonl"))
        totals[project][0] += 1
        totals[project][1] += tr.prompts

        # Now and then Claude delegates to a subagent for a few minutes inside the session.
        if len(events) > 20 and rng.random() < 0.25:
            s = events[rng.randrange(len(events) // 2)][1]
            sub = Transcript(rng, project, sid, sidechain=True)
            sub.prompt(s, "Search the codebase for every caller of the function we just changed")
            t = s
            for _ in range(rng.randint(8, 30)):
                t += timedelta(seconds=rng.uniform(3, 20))
                if t >= end:
                    break
                sub.tool(t)
            sub.write(os.path.join(folder, sid, "subagents", "agent-%08x.jsonl" % rng.getrandbits(32)))
            totals[project][1] += sub.prompts  # Claude Time counts the subagent's task prompt too

    print("Demo transcripts: %s" % out)
    for p, (n, k) in totals.items():
        print("  %-15s %3d session%s  %4d prompt%s" % (p, n, "" if n == 1 else "s", k, "" if k == 1 else "s"))


if __name__ == "__main__":
    main()
