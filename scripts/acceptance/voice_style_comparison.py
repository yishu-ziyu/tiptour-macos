#!/usr/bin/env python3
"""Compare the two voice styles on the same spoken turns, for the user's ear.

  voice_style_comparison.py inputs <out-dir> "句子一" "句子二" ...
      Synthesizes the turns (macOS `say`, 24 kHz PCM16) and prints the probe commands.
  voice_style_comparison.py page <realtime-probe-dir> <stable-probe-dir> <out-dir>
      Runs voice_consistency_report on both, writes each reply as WAV and an
      index.html that puts the two styles side by side: what she heard, what she
      said, how long after the end of the user's speech her first sound came,
      and whether the voice changed between replies.

The realtime probe commits each turn by hand, so its wait excludes server VAD's
end-of-speech detection; the stable probe's wait starts at the simulated release.
"""
from __future__ import annotations

import html
import json
import sys
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runner.synthetic_speech import synthesize_utterance  # noqa: E402
from voice_consistency_report import analyze_probe_directory  # noqa: E402

SAMPLE_RATE_HZ = 24000


def write_inputs(out_dir: Path, sentences: list[str]) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    utterances = [synthesize_utterance(sentence, out_dir) for sentence in sentences]
    (out_dir / "inputs.json").write_text(
        json.dumps([u.to_dict() for u in utterances], ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    paths = " ".join(f'"{u.pcm_path}"' for u in utterances)
    print("HER=~/Library/Developer/Xcode/DerivedData/tiptour-macos-gtcdcfrkrqlavldfoxxsyfksnyrq/Build/Products/Debug/Her.app/Contents/MacOS/Her")
    print(f'"$HER" --voice-consistency-probe "$(defaults read com.yishuziyu.her stepfunRealtimeVoice 2>/dev/null || echo wenroushunv)" {out_dir}/realtime {paths}')
    print(f'"$HER" --stable-voice-probe {out_dir}/stable {paths}')


def pcm_to_wav(pcm_path: Path, wav_path: Path) -> None:
    with wave.open(str(wav_path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE_HZ)
        wav.writeframes(pcm_path.read_bytes())


def style_column(label: str, probe_dir: Path, out_dir: Path, prefix: str) -> tuple[str, list[dict]]:
    summary = json.loads((probe_dir / "summary.json").read_text(encoding="utf-8"))
    report = analyze_probe_directory(probe_dir)
    rows = []
    for turn, reply in zip(summary.get("turns", []), report["replies"]):
        wav_name = f"{prefix}-{turn['audio_file'].replace('.pcm', '.wav')}"
        pcm_to_wav(probe_dir / turn["audio_file"], out_dir / wav_name)
        playback = reply.get("playback") or {}
        rows.append({
            "turn": turn["turn"], "heard": turn.get("heard", ""), "said": turn.get("transcript", ""),
            "wav": wav_name, "first_audio_ms": playback.get("first_audio_after_commit_ms"),
            "gaps": playback.get("underruns_without_preroll"), "failure": turn.get("failure", ""),
        })
    changes = report["voice_change_count"]
    verdict = "没测出换声" if changes == 0 else f"测出 {changes} 次换声"
    return f"{label}（{verdict}{'；出错：' + report['probe_error'] if report['probe_error'] else ''}）", rows


def write_page(realtime_dir: Path, stable_dir: Path, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    columns = [style_column("随时能插嘴", realtime_dir, out_dir, "realtime"),
               style_column("声音稳定", stable_dir, out_dir, "stable")]
    turn_count = max(len(rows) for _, rows in columns)

    def cell(row: dict | None) -> str:
        if row is None:
            return "<td>没有这一轮</td>"
        wait = f"{row['first_audio_ms'] / 1000:.1f} 秒" if row["first_audio_ms"] is not None else "没出声"
        heard = f"<div class=heard>她听成：{html.escape(row['heard'])}</div>" if row["heard"] else ""
        failure = f"<div class=bad>{html.escape(row['failure'])}</div>" if row["failure"] else ""
        return (f"<td>{heard}<div class=said>{html.escape(row['said']) or '（没有文字）'}</div>"
                f"<audio controls preload=none src='{row['wav']}'></audio>"
                f"<div class=wait>说完到她出声：<b>{wait}</b></div>{failure}</td>")

    body = "".join(
        "<tr><th>第 %d 句</th>%s</tr>" % (index + 1, "".join(
            cell(rows[index] if index < len(rows) else None) for _, rows in columns))
        for index in range(turn_count))
    page = f"""<!doctype html><html lang=zh><meta charset=utf-8><title>两种说话方式对比</title>
<style>body{{font:15px/1.6 -apple-system,"PingFang SC",sans-serif;background:#f4f1ea;color:#1d1c1a;margin:0}}
.wrap{{max-width:1100px;margin:0 auto;padding:28px 24px}}table{{border-collapse:collapse;width:100%;background:#fff;border-radius:12px;overflow:hidden}}
th,td{{border-bottom:1px solid #e2dcd0;padding:12px;text-align:left;vertical-align:top}}thead th{{background:#faf8f3}}
.heard{{color:#8b867d;font-size:13px}}.said{{margin:4px 0 8px}}.wait{{font-size:13px;margin-top:6px}}.bad{{color:#c0392b;font-size:13px}}
audio{{width:100%}}p{{color:#4a463f}}</style><div class=wrap>
<h1>同样几句话，两种说话方式</h1>
<p>左边是现在的实时语音，右边是新加的「声音稳定」。点播放听她的回答；「说完到她出声」从你说完那一刻算。
实时语音这边是程序直接告诉服务器「说完了」，真用的时候还要多等服务器自己判断你说完的那一段。</p>
<table><thead><tr><th></th><th>{html.escape(columns[0][0])}</th><th>{html.escape(columns[1][0])}</th></tr></thead>
<tbody>{body}</tbody></table></div>"""
    (out_dir / "index.html").write_text(page, encoding="utf-8")
    print(out_dir / "index.html")


def main() -> int:
    if len(sys.argv) >= 4 and sys.argv[1] == "inputs":
        write_inputs(Path(sys.argv[2]), sys.argv[3:])
        return 0
    if len(sys.argv) == 5 and sys.argv[1] == "page":
        write_page(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
