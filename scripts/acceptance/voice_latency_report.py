#!/usr/bin/env python3
"""Measure Her's response and barge-in latencies from a real-microphone voice session.

  record  Stream Her's VoiceTask unified-log events while you talk to her.
          Press Ctrl-C when done; the raw events and the report are written to
          out/acceptance/voice-latency-<UTC time>/.
  recent  Pull the last --minutes of events after a session (same output).
  report  Recompute the report from a saved events.ndjson.

Only public telemetry metadata is read (event names, turn IDs, timings). No
audio, transcript or credential passes through this script.

Metrics (see docs/development/2026-09-23-voice-conversation-quality.md, P5):
  user_speech_end_to_first_audio_ms  estimated end of the user's speech (last
      loud echo-cancelled mic buffer) -> first audio of her reply. This includes
      the server's silence window, which the user waits through.
  speech_stop_to_first_audio_ms  the server's `speech_stopped` -> first audio.
      Excludes that silence window, so it understates what the user feels.
  Both use the first `realtime_audio_started` per user turn and exclude buffered
  receipt audio (held until its transcript is checked, so its arrival is not
  when the user hears it).
  barge_in_estimated_ms  estimated user onset while she was speaking -> the
      server reporting the interruption (local playback stops at that moment).
      An upper bound: background noise can make the estimated onset early.
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SUBSYSTEM = "com.yishuziyu.her"
CATEGORY = "VoiceTask"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
LOG_STREAM_COMMAND = [
    "/usr/bin/log", "stream", "--level", "info", "--style", "ndjson",
    "--predicate", f'subsystem == "{SUBSYSTEM}" AND category == "{CATEGORY}"',
]


def parse_voice_events(ndjson_lines: list[str]) -> list[dict]:
    """Return Her's own trace records; log-stream banners and foreign lines are skipped."""
    voice_events = []
    for line in ndjson_lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            log_entry = json.loads(line)
            trace_record = json.loads(log_entry.get("eventMessage", ""))
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(trace_record, dict) and "event" in trace_record:
            voice_events.append(trace_record)
    return voice_events


def summarize(sample_values: list[int]) -> dict:
    if not sample_values:
        return {"count": 0, "p50_ms": None, "min_ms": None, "max_ms": None, "samples_ms": []}
    return {
        "count": len(sample_values),
        "p50_ms": statistics.median(sample_values),
        "min_ms": min(sample_values),
        "max_ms": max(sample_values),
        "samples_ms": sample_values,
    }


def build_report(voice_events: list[dict], events_path: Path) -> dict:
    speech_stop_samples: list[int] = []
    user_speech_end_samples: list[int] = []
    barge_in_peak_dbfs_samples: list[int] = []
    voices_used: list[str] = []
    turns_with_first_audio_counted: set[str] = set()
    excluded_receipt_audio_count = 0
    first_audio_without_speech_stop_count = 0
    barge_in_samples: list[int] = []
    barge_in_without_onset_count = 0

    for trace_record in voice_events:
        event_name = trace_record.get("event")
        metadata = trace_record.get("metadata", {})
        turn_id = trace_record.get("turn_id", "")
        if event_name == "realtime_audio_started":
            if turn_id in turns_with_first_audio_counted:
                continue
            if metadata.get("buffered_receipt") == "true":
                excluded_receipt_audio_count += 1
                continue
            milliseconds_since_speech_stopped = metadata.get("ms_since_speech_stopped")
            if milliseconds_since_speech_stopped is None:
                first_audio_without_speech_stop_count += 1
                continue
            turns_with_first_audio_counted.add(turn_id)
            speech_stop_samples.append(int(milliseconds_since_speech_stopped))
            milliseconds_since_user_speech_end = metadata.get("ms_since_estimated_user_speech_end")
            if milliseconds_since_user_speech_end is not None:
                user_speech_end_samples.append(int(milliseconds_since_user_speech_end))
        elif event_name == "voice_session_starting":
            voices_used.append(metadata.get("voice", "unknown"))
        elif event_name == "barge_in_detected":
            if metadata.get("mic_peak_dbfs_while_speaking") is not None:
                barge_in_peak_dbfs_samples.append(int(metadata["mic_peak_dbfs_while_speaking"]))
            milliseconds_since_onset = metadata.get("ms_since_estimated_user_onset")
            if milliseconds_since_onset is None:
                barge_in_without_onset_count += 1
            else:
                barge_in_samples.append(int(milliseconds_since_onset))

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "events_file": str(events_path),
        "voice_event_count": len(voice_events),
        "voices_used": voices_used,
        "targets_ms": {"user_speech_end_to_first_audio_p50": 1200, "barge_in_p50": 500},
        "user_speech_end_to_first_audio_ms": summarize(user_speech_end_samples),
        "speech_stop_to_first_audio_ms": summarize(speech_stop_samples),
        "speech_stop_excluded": {
            "buffered_receipt_audio": excluded_receipt_audio_count,
            "no_speech_stop_in_turn": first_audio_without_speech_stop_count,
        },
        "barge_in_estimated_ms": summarize(barge_in_samples),
        "barge_in_without_local_onset": barge_in_without_onset_count,
        "barge_in_mic_peak_dbfs": barge_in_peak_dbfs_samples,
        "barge_in_note": "upper bound; onset is the first sustained loud echo-cancelled mic buffer while she spoke",
    }


def write_report(events_path: Path) -> Path:
    voice_events = parse_voice_events(events_path.read_text(encoding="utf-8").splitlines())
    report = build_report(voice_events, events_path)
    report_path = events_path.with_name("latency.json")
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"voices_used: {report['voices_used']}")
    for metric_name in ("user_speech_end_to_first_audio_ms", "speech_stop_to_first_audio_ms", "barge_in_estimated_ms"):
        metric = report[metric_name]
        print(f"{metric_name}: n={metric['count']} p50={metric['p50_ms']} min={metric['min_ms']} max={metric['max_ms']}")
    print(f"barge_in_without_local_onset: {report['barge_in_without_local_onset']}")
    print(f"Report: {report_path}")
    return report_path


def record() -> int:
    run_directory = new_run_directory()
    events_path = run_directory / "events.ndjson"
    (run_directory / "command.json").write_text(json.dumps({"log_stream": LOG_STREAM_COMMAND}, indent=2) + "\n")
    print(f"Recording Her voice events to {events_path}")
    print("Start a voice session (Ctrl+Option), talk normally, and talk over her a few times. Press Ctrl-C to finish.")
    with events_path.open("w", encoding="utf-8") as events_file:
        log_stream_process = subprocess.Popen(LOG_STREAM_COMMAND, stdout=events_file, stderr=subprocess.DEVNULL)
        try:
            log_stream_process.wait()
        except KeyboardInterrupt:
            log_stream_process.terminate()
            log_stream_process.wait(timeout=5)
    write_report(events_path)
    return 0


def recent(minutes: int) -> int:
    """Pull events after the fact. Info-level entries live in memory, so this
    only reaches back as far as the system has kept them (tens of minutes)."""
    run_directory = new_run_directory()
    events_path = run_directory / "events.ndjson"
    log_show_command = [
        "/usr/bin/log", "show", "--info", "--last", f"{minutes}m", "--style", "ndjson",
        "--predicate", f'subsystem == "{SUBSYSTEM}" AND category == "{CATEGORY}"',
    ]
    (run_directory / "command.json").write_text(json.dumps({"log_show": log_show_command}, indent=2) + "\n")
    with events_path.open("w", encoding="utf-8") as events_file:
        subprocess.run(log_show_command, stdout=events_file, stderr=subprocess.DEVNULL, check=False)
    write_report(events_path)
    return 0


def new_run_directory() -> Path:
    run_directory = REPOSITORY_ROOT / "out" / "acceptance" / (
        "voice-latency-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    run_directory.mkdir(parents=True, exist_ok=True)
    return run_directory


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("record")
    recent_parser = subcommands.add_parser("recent")
    recent_parser.add_argument("--minutes", type=int, default=30)
    report_parser = subcommands.add_parser("report")
    report_parser.add_argument("events", type=Path)
    options = parser.parse_args()
    if options.command == "record":
        return record()
    if options.command == "recent":
        return recent(options.minutes)
    write_report(options.events.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
