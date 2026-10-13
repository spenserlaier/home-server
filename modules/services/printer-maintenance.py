"""Observe IPP history and submit at most one tracked color exercise page."""

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time
import uuid

DAY = 86400
ATTRIBUTES = (
    "job-id,job-name,job-state,job-state-reasons,date-time-at-completed,"
    "time-at-completed,job-printer-up-time,job-impressions-completed,print-color-mode"
)


def ipp_value(value):
    # IPP nameWithLanguage/textWithLanguage values are plist dictionaries, while
    # nameWithoutLanguage/textWithoutLanguage values are plain strings.
    if isinstance(value, dict) and "string" in value and "language" in value:
        return value["string"]
    if isinstance(value, list):
        return [ipp_value(item) for item in value]
    return value


def query(uri, operation, attributes, which=None):
    extra = ""
    if which:
        extra = f"ATTR keyword which-jobs {which}\nATTR boolean my-jobs false\n"
    request = (
        "{\n"
        f"OPERATION {operation}\n"
        "GROUP operation-attributes-tag\n"
        "ATTR charset attributes-charset utf-8\n"
        "ATTR language attributes-natural-language en\n"
        "ATTR uri printer-uri $uri\n"
        "ATTR name requesting-user-name $user\n"
        f"{extra}ATTR keyword requested-attributes {attributes}\n"
        "STATUS successful-ok\n}\n"
    )
    with tempfile.NamedTemporaryFile(mode="w", suffix=".test") as test:
        test.write(request)
        test.flush()
        result = subprocess.run(
            ["ipptool", "-T", "10", "-X", uri, test.name],
            capture_output=True, check=True, timeout=20,
        )
    report = plistlib.loads(result.stdout)
    if not report["Successful"] or len(report["Tests"]) != 1:
        raise RuntimeError("IPP query failed")
    return [
        {name: ipp_value(value) for name, value in group.items()}
        for group in report["Tests"][0]["ResponseAttributes"]
    ]


def jobs(uri, which):
    return [job for job in query(uri, "Get-Jobs", ATTRIBUTES, which) if "job-id" in job]


def successful(job):
    reasons = job.get("job-state-reasons", [])
    if isinstance(reasons, str):
        reasons = [reasons]
    return (
        job.get("job-state") == 9
        and not any(reason.startswith("job-completed-with-") for reason in reasons)
        and job.get("job-impressions-completed", 1) > 0
    )


def completion(job, now):
    stamp = job.get("date-time-at-completed")
    if isinstance(stamp, dt.datetime):
        # plistlib returns naive UTC datetimes on older Python releases.
        stamp = stamp.replace(tzinfo=dt.timezone.utc).timestamp()
    else:
        finished = job.get("time-at-completed")
        uptime = job.get("job-printer-up-time")
        if not isinstance(finished, int) or not isinstance(uptime, int) or not 0 <= finished <= uptime:
            return None
        stamp = now - (uptime - finished)
    # Bad printer clocks must not postpone maintenance indefinitely.
    return min(stamp, now) if 0 < stamp <= now + 300 else None


def save(path, state):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(state, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def observe(state, history, now):
    for job in history:
        if successful(job):
            stamp = completion(job, now)
            if stamp is not None:
                state["last_success"] = max(state.get("last_success", 0), stamp)


def reconcile(state, physical, local, now):
    pending = state.get("pending")
    if not pending:
        return
    printed = [job for job in physical if job.get("job-name") == pending["title"]]
    if any(successful(job) for job in printed):
        # Confirmation is observed now; conservative when the printer clock is bad.
        state["last_maintenance"] = now
        state["last_success"] = now
        state["pending"] = None
        print("Printer confirmed successful maintenance completion", flush=True)
        return
    tracked = [job for job in local if job.get("job-name") == pending["title"]]
    if len(tracked) > 1:
        raise RuntimeError("Multiple CUPS jobs match the maintenance token; review required")
    if not tracked:
        raise RuntimeError("Maintenance handoff is ambiguous or history expired; review required")
    job = tracked[0]
    if job.get("job-state") in (7, 8):
        state["pending"] = None
        print("Maintenance job canceled/aborted; retry no earlier than 24 hours after submission", flush=True)
    elif job.get("job-state") == 9:
        raise RuntimeError("CUPS completed the job but printer completion is unconfirmed; review required")
    else:
        print("Maintenance job is still queued/processing; no additional page", flush=True)


def due(state, now, idle_days, maximum_days):
    if state.get("pending"):
        return None
    if now - state.get("last_attempt", 0) < DAY:
        return None
    last_success = state.get("last_success", state["initialized"])
    last_maintenance = state.get("last_maintenance", state["initialized"])
    if now - last_maintenance >= maximum_days * DAY:
        return "maximum interval between dedicated color pages"
    if now - last_success >= idle_days * DAY:
        return "printer idle interval"
    return None


def exercise_pdf(now):
    # A native vector PDF: small full-width bands and fine lines, rather than
    # ink-heavy solid pages. Color management may mix inks; this is not a
    # firmware nozzle check and cannot certify that every nozzle fired.
    stamp = dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    commands = [
        "BT /F1 16 Tf 54 738 Td (Epson color exercise) Tj ET",
        f"BT /F1 10 Tf 54 718 Td ({stamp}) Tj ET",
        "BT /F1 10 Tf 54 698 Td (Inspect the bands for gaps or streaks.) Tj ET",
    ]
    colors = [("Black", "0 0 0 1"), ("Cyan", "1 0 0 0"), ("Magenta", "0 1 0 0"), ("Yellow", "0 0 1 0")]
    for index, (label, color) in enumerate(colors):
        y = 650 - index * 70
        commands.append(f"0 0 0 1 k BT /F1 10 Tf 54 {y + 15} Td ({label}) Tj ET")
        commands.append(f"{color} k 54 {y} 504 6 re f {color} K 0.5 w")
        for offset in (12, 18, 24):
            commands.append(f"54 {y - offset} m 558 {y - offset} l S")
    content = ("\n".join(commands) + "\n").encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        f"<< /Length {len(content)} >>\nstream\n".encode() + content + b"endstream",
    ]
    document = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(document))
        document.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(document)
    document.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        document.extend(f"{offset:010d} 00000 n \n".encode())
    document.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(document)


def run(args):
    now = time.time()
    root = Path(args.state_directory)
    path = root / "state.json"
    state = json.loads(path.read_text()) if path.exists() else {"version": 1, "initialized": now}
    if state.get("version") != 1:
        raise RuntimeError("Unknown maintenance state version")
    local_uri = f"ipp://localhost:631/printers/{args.queue}"
    try:
        history = jobs(args.printer_uri, "completed")
        printer = query(args.printer_uri, "Get-Printer-Attributes", "printer-state,printer-state-reasons,printer-is-accepting-jobs,queued-job-count")[-1]
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print("Printer unavailable; skipping this check without submitting a job", flush=True)
        return
    observe(state, history, now)
    local_pending = jobs(local_uri, "not-completed")
    if state.get("pending"):
        reconcile(state, history, local_pending + jobs(local_uri, "completed"), now)
    if not args.dry_run:
        save(path, state)
    reason = due(state, now, args.idle_days, args.maximum_days)
    if not reason:
        print("No maintenance page due (or an existing attempt is outstanding)", flush=True)
        return
    if (
        printer.get("printer-state") != 3
        or not printer.get("printer-is-accepting-jobs", False)
        or printer.get("queued-job-count", 0) > 0
        or local_pending
        or printer.get("printer-state-reasons", "none") not in ("none", ["none"])
    ):
        print("Maintenance due, but printer is busy or needs attention; deferring", flush=True)
        return
    print(f"Maintenance page due: {reason}", flush=True)
    if args.dry_run:
        print("Dry run: no state changes or print submission", flush=True)
        return
    page = root / "exercise.pdf"
    page.write_bytes(exercise_pdf(now))
    title = "homeserver-color-exercise-" + str(uuid.uuid4())
    state["pending"] = {"title": title, "submitted": now}
    state["last_attempt"] = now
    # Persist before calling lp. A crash or lost response must never cause an
    # automatic second submission. Recover using the unique job title instead.
    save(path, state)
    result = subprocess.run(
        ["lp", "-d", args.queue, "-t", title, "-n", "1", "-o", "sides=one-sided", "-o", "media=na_letter_8.5x11in", "-o", "media-type=stationery", "-o", "print-color-mode=color", "-o", "print-quality=4", str(page)],
        capture_output=True, text=True, check=True, timeout=30,
    )
    match = re.search(r"request id is " + re.escape(args.queue) + r"-(\d+)", result.stdout)
    if match:
        state["pending"]["cups_job_id"] = int(match[1])
        save(path, state)
    print(f"Submitted maintenance job {title}", flush=True)
    # Observe promptly because embedded printers may retain very few jobs.
    for _ in range(12):
        time.sleep(10)
        history = jobs(args.printer_uri, "completed")
        if any(job.get("job-name") == title and successful(job) for job in history):
            reconcile(state, history, [], time.time())
            save(path, state)
            return
    print("Completion not yet observed; keeping the outstanding job for the next check", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-directory", required=True)
    parser.add_argument("--printer-uri", required=True)
    parser.add_argument("--queue", required=True)
    parser.add_argument("--idle-days", type=int, default=7)
    parser.add_argument("--maximum-days", type=int, default=14)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.idle_days < 1 or args.maximum_days < args.idle_days:
        parser.error("Require 1 <= idle-days <= maximum-days")
    os.umask(0o077)
    if args.dry_run:
        run(args)
    else:
        with (Path(args.state_directory) / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            run(args)


if __name__ == "__main__":
    main()
