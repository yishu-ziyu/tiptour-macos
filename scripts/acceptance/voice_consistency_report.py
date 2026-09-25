#!/usr/bin/env python3
"""Measure speaker drift between the replies of one realtime voice session.

Input: the directory written by `Her --voice-consistency-probe` (summary.json and
turn-NN.pcm, headerless PCM16 24 kHz mono). Output: consistency.json beside them.

Per reply:
  f0_median_hz          median pitch over voiced frames (librosa pyin)
  timbre                mean MFCC 1-19 over voiced frames (c0 = loudness, dropped)
  within_turn_distance  timbre distance between the reply's own first and second
                        half: how much one speaker varies inside one reply

Between consecutive replies:
  pitch_shift_semitones   difference of the two f0 medians
  timbre_distance         distance between the two timbre vectors
  drift_ratio             timbre_distance / larger within_turn_distance of the pair

A pair is flagged as a voice change when drift_ratio >= 1.6 or
|pitch_shift_semitones| >= 5. Calibrated on the self-check below (macOS `say`):
one speaker stayed <= 0.81 ratio / 0.8 st, a female->female speaker change
was 2.26 ratio / 3.4 st, female->male 3.05 / 14.5 st. Pitch is held to a
gender-sized jump because expressive speech moves pitch between replies. The
raw numbers are always reported so the thresholds can be revised on real audio.

Resolution limit, measured on 8 real StepFun runs (2026-09-23): the official
voice reached drift_ratio 1.65 once (after a 1.6 s, seven-character reply) and
the custom clone's flagged pairs were 1.73-2.11 (one with a 6.45 st drop).
A session-median baseline did not separate them better. Treat ratios of about
1.5-1.7 without a large pitch shift as ambiguous; only clear flags count, and
the user's ear is the final judge.

  voice_consistency_report.py <probe-output-dir>
  voice_consistency_report.py --self-check    # same vs different macOS `say` voices
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import librosa
import numpy as np

SAMPLE_RATE_HZ = 24000
MINIMUM_VOICED_SECONDS = 0.6
PITCH_SHIFT_FLAG_SEMITONES = 5.0
DRIFT_RATIO_FLAG = 1.6


def load_pcm16(pcm_path: Path) -> np.ndarray:
    samples = np.frombuffer(pcm_path.read_bytes(), dtype="<i2").astype(np.float32) / 32768.0
    trimmed, _ = librosa.effects.trim(samples, top_db=35)
    return trimmed


def pitch_range_semitones(samples: np.ndarray) -> float | None:
    """Interquartile range of pitch inside one reply: a flat, read-aloud delivery is small."""
    if samples.size < SAMPLE_RATE_HZ * 0.3:
        return None
    f0, voiced_flags, _ = librosa.pyin(samples, fmin=65, fmax=500, sr=SAMPLE_RATE_HZ,
                                       frame_length=1024, hop_length=256)
    voiced_f0 = f0[voiced_flags]
    if voiced_f0.size < 10:
        return None
    lower_quartile, upper_quartile = np.percentile(voiced_f0, [25, 75])
    return float(12 * np.log2(upper_quartile / lower_quartile))


def voiced_features(samples: np.ndarray) -> tuple[float | None, np.ndarray | None, float]:
    """Return (median f0, mean timbre vector, voiced seconds) for one stretch of audio."""
    if samples.size < SAMPLE_RATE_HZ * 0.3:
        return None, None, 0.0
    hop_length = 256
    f0, voiced_flags, _ = librosa.pyin(samples, fmin=65, fmax=500, sr=SAMPLE_RATE_HZ,
                                       frame_length=1024, hop_length=hop_length)
    mfcc = librosa.feature.mfcc(y=samples, sr=SAMPLE_RATE_HZ, n_mfcc=20, hop_length=hop_length)[1:]
    frame_count = min(mfcc.shape[1], voiced_flags.shape[0])
    voiced_mask = voiced_flags[:frame_count]
    voiced_seconds = float(voiced_mask.sum() * hop_length / SAMPLE_RATE_HZ)
    if voiced_mask.sum() < 5:
        return None, None, voiced_seconds
    median_f0 = float(np.nanmedian(f0[:frame_count][voiced_mask]))
    timbre_vector = mfcc[:, :frame_count][:, voiced_mask].mean(axis=1)
    return median_f0, timbre_vector, voiced_seconds


def timbre_distance(first_vector: np.ndarray, second_vector: np.ndarray) -> float:
    return float(np.linalg.norm(first_vector - second_vector))


def analyze_reply(samples: np.ndarray) -> dict:
    median_f0, timbre_vector, voiced_seconds = voiced_features(samples)
    half_index = samples.size // 2
    _, first_half_timbre, _ = voiced_features(samples[:half_index])
    _, second_half_timbre, _ = voiced_features(samples[half_index:])
    within_turn_distance = (timbre_distance(first_half_timbre, second_half_timbre)
                            if first_half_timbre is not None and second_half_timbre is not None else None)
    pitch_range = pitch_range_semitones(samples)
    return {
        "duration_seconds": round(samples.size / SAMPLE_RATE_HZ, 2),
        "voiced_seconds": round(voiced_seconds, 2),
        "pitch_range_semitones": round(pitch_range, 2) if pitch_range is not None else None,
        "usable": timbre_vector is not None and voiced_seconds >= MINIMUM_VOICED_SECONDS,
        "f0_median_hz": round(median_f0, 1) if median_f0 else None,
        "within_turn_distance": round(within_turn_distance, 2) if within_turn_distance is not None else None,
        "_timbre": timbre_vector,
    }


def playback_continuity(chunk_arrivals: list[list[int]]) -> dict | None:
    """Replay chunk arrival times against a player that starts on the first chunk.

    An underrun is a chunk arriving after everything before it has already
    played: an audible gap inside the reply. `preroll_ms_for_no_underrun` is the
    start delay that would have hidden every gap in this reply.
    """
    if not chunk_arrivals:
        return None
    first_arrival_ms = chunk_arrivals[0][0]
    playback_end_ms = float(first_arrival_ms)
    audio_before_chunk_ms = 0.0
    underrun_gaps_ms = []
    odd_byte_chunks = 0
    preroll_needed_ms = 0.0
    for arrival_ms, chunk_bytes in chunk_arrivals:
        odd_byte_chunks += chunk_bytes % 2
        chunk_duration_ms = chunk_bytes / 2 / SAMPLE_RATE_HZ * 1000
        if arrival_ms > playback_end_ms + 1:
            underrun_gaps_ms.append(round(arrival_ms - playback_end_ms))
        playback_end_ms = max(playback_end_ms, arrival_ms) + chunk_duration_ms
        preroll_needed_ms = max(preroll_needed_ms, arrival_ms - (first_arrival_ms + audio_before_chunk_ms))
        audio_before_chunk_ms += chunk_duration_ms
    return {
        "chunk_count": len(chunk_arrivals),
        "first_audio_after_commit_ms": first_arrival_ms,
        "audio_ms": round(audio_before_chunk_ms),
        "arrival_span_ms": chunk_arrivals[-1][0] - first_arrival_ms,
        "underruns_without_preroll": len(underrun_gaps_ms),
        "largest_gap_ms": max(underrun_gaps_ms, default=0),
        "preroll_ms_for_no_underrun": round(preroll_needed_ms),
        "odd_byte_chunks": odd_byte_chunks,
    }


def compare_replies(reply_analyses: list[dict]) -> list[dict]:
    comparisons = []
    for previous_reply, next_reply in zip(reply_analyses, reply_analyses[1:]):
        comparison = {"from_turn": previous_reply["turn"], "to_turn": next_reply["turn"]}
        if not (previous_reply["usable"] and next_reply["usable"]):
            comparison["status"] = "not_enough_voiced_audio"
            comparisons.append(comparison)
            continue
        pitch_shift = 12 * np.log2(next_reply["f0_median_hz"] / previous_reply["f0_median_hz"])
        distance = timbre_distance(previous_reply["_timbre"], next_reply["_timbre"])
        baseline = max(previous_reply["within_turn_distance"] or 0, next_reply["within_turn_distance"] or 0)
        drift_ratio = distance / baseline if baseline > 0 else None
        is_voice_change = abs(pitch_shift) >= PITCH_SHIFT_FLAG_SEMITONES or (
            drift_ratio is not None and drift_ratio >= DRIFT_RATIO_FLAG)
        comparison.update({
            "pitch_shift_semitones": round(float(pitch_shift), 2),
            "timbre_distance": round(distance, 2),
            "drift_ratio": round(drift_ratio, 2) if drift_ratio is not None else None,
            "status": "voice_change" if is_voice_change else "consistent",
        })
        comparisons.append(comparison)
    return comparisons


def analyze_probe_directory(probe_directory: Path) -> dict:
    summary = json.loads((probe_directory / "summary.json").read_text(encoding="utf-8"))
    reply_analyses = []
    for turn_record in summary.get("turns", []):
        reply_analysis = analyze_reply(load_pcm16(probe_directory / turn_record["audio_file"]))
        reply_analysis["turn"] = turn_record["turn"]
        reply_analysis["transcript"] = turn_record.get("transcript", "")
        reply_analysis["playback"] = playback_continuity(turn_record.get("chunk_arrivals", []))
        reply_analyses.append(reply_analysis)
    comparisons = compare_replies(reply_analyses)
    report = {
        "probe_directory": str(probe_directory),
        "model": summary.get("model"), "voice": summary.get("voice"),
        "voice_matches_request": summary.get("voice_matches_request"),
        "probe_error": summary.get("error", ""),
        "thresholds": {"pitch_shift_semitones": PITCH_SHIFT_FLAG_SEMITONES, "drift_ratio": DRIFT_RATIO_FLAG},
        "replies": [{key: value for key, value in reply.items() if key != "_timbre"} for reply in reply_analyses],
        "comparisons": comparisons,
        "voice_change_count": sum(comparison["status"] == "voice_change" for comparison in comparisons),
    }
    (probe_directory / "consistency.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def print_report(report: dict) -> None:
    print(f"voice={report['voice']} matches_request={report['voice_matches_request']} error={report['probe_error'] or '-'}")
    for reply in report["replies"]:
        print(f"  turn {reply['turn']}: {reply['duration_seconds']}s f0={reply['f0_median_hz']}Hz "
              f"range={reply['pitch_range_semitones']}st within={reply['within_turn_distance']} "
              f"usable={reply['usable']} | {reply['transcript'][:40]}")
        if reply.get("playback"):
            playback = reply["playback"]
            print(f"      playback: chunks={playback['chunk_count']} audio={playback['audio_ms']}ms "
                  f"arrived_over={playback['arrival_span_ms']}ms underruns={playback['underruns_without_preroll']} "
                  f"largest_gap={playback['largest_gap_ms']}ms preroll_needed={playback['preroll_ms_for_no_underrun']}ms "
                  f"odd_chunks={playback['odd_byte_chunks']}")
    for comparison in report["comparisons"]:
        print(f"  {comparison['from_turn']}->{comparison['to_turn']}: {comparison['status']} "
              f"pitch={comparison.get('pitch_shift_semitones')}st timbre={comparison.get('timbre_distance')} "
              f"ratio={comparison.get('drift_ratio')}")
    print(f"voice_change_count={report['voice_change_count']}")


def synthesize_say_reply(voice_name: str, text: str, pcm_path: Path) -> None:
    aiff_path = pcm_path.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice_name, "-o", str(aiff_path), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE_HZ}", "-c", "1",
                    str(aiff_path), str(pcm_path.with_suffix(".wav"))], check=True)
    wav_bytes = pcm_path.with_suffix(".wav").read_bytes()
    pcm_path.write_bytes(wav_bytes[wav_bytes.find(b"data") + 8:])


def self_check() -> int:
    """The evaluator must flag a real speaker change and pass a single speaker."""
    lines = ["今天天气不错，我们出去走走吧。", "我刚才看了一下，你的日程下午是空的。",
             "要不要我帮你把会议挪到明天上午？", "好的，那我就先记下来了。"]
    male_voice = "Eddy (中文（中国大陆）)"
    other_female_voice = "Flo (中文（中国大陆）)"
    cases = {
        "same_speaker": ["Tingting"] * 4,
        "male_change_at_turn_3": ["Tingting", "Tingting", male_voice, male_voice],
        "female_change_at_turn_3": ["Tingting", "Tingting", other_female_voice, other_female_voice],
    }
    all_expectations_met = True
    for case_name, voice_names in cases.items():
        with tempfile.TemporaryDirectory(prefix=f"her-consistency-{case_name}-") as temporary_directory:
            probe_directory = Path(temporary_directory)
            turn_records = []
            for turn_index, (voice_name, text) in enumerate(zip(voice_names, lines), start=1):
                audio_file = f"turn-{turn_index:02d}.pcm"
                synthesize_say_reply(voice_name, text, probe_directory / audio_file)
                turn_records.append({"turn": turn_index, "audio_file": audio_file, "transcript": text})
            (probe_directory / "summary.json").write_text(json.dumps(
                {"model": "macos-say", "voice": case_name, "turns": turn_records}), encoding="utf-8")
            report = analyze_probe_directory(probe_directory)
            print(f"[{case_name}]")
            print_report(report)
            flagged_turns = [comparison["to_turn"] for comparison in report["comparisons"]
                             if comparison["status"] == "voice_change"]
            expected_flags = [] if case_name == "same_speaker" else [3]
            if flagged_turns != expected_flags:
                all_expectations_met = False
                print(f"  EXPECTED voice changes at {expected_flags}, got {flagged_turns}")
    print("SELF_CHECK=" + ("PASS" if all_expectations_met else "FAIL"))
    return 0 if all_expectations_met else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("probe_directory", type=Path, nargs="?")
    parser.add_argument("--self-check", action="store_true")
    options = parser.parse_args()
    if options.self_check:
        return self_check()
    if options.probe_directory is None:
        parser.error("probe_directory is required unless --self-check is given")
    print_report(analyze_probe_directory(options.probe_directory.resolve()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
