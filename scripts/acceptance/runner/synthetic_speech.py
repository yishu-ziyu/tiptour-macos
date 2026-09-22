"""Synthetic PCM input for the real-provider probes.

The probes take headerless 24 kHz mono PCM16 (tools/voice-acceptance/README.md).
The runner synthesizes it with the system `say` + `afconvert` pipeline so no
private audio ever enters the repository or the evidence package: only metadata
about the generated file is recorded, never samples. A placeholder generator
exists for self-tests only and is always labeled `is_real_speech: false`.
"""
from __future__ import annotations

import hashlib
import shutil
import subprocess
import wave
from dataclasses import dataclass
from pathlib import Path

PCM_SAMPLE_RATE_HZ = 24000
PCM_CHANNELS = 1
PCM_SAMPLE_WIDTH_BYTES = 2

# Preferred Mandarin voices, best first. Anything zh_CN works; the recorded
# voice name keeps the evidence reproducible.
PREFERRED_VOICE_NAMES = ("Tingting", "Sinji", "Meijia", "Eddy", "Flo", "Reed")


class SpeechSynthesisError(RuntimeError):
    pass


@dataclass
class UtteranceAudio:
    text: str
    pcm_path: Path
    byte_count: int
    duration_seconds: float
    voice: str
    is_real_speech: bool
    cached: bool
    synthesis_method: str

    def to_dict(self) -> dict:
        # Metadata only: the samples themselves never enter the evidence.
        return {
            "text": self.text,
            "pcm_path": str(self.pcm_path),
            "byte_count": self.byte_count,
            "duration_seconds": round(self.duration_seconds, 3),
            "voice": self.voice,
            "is_real_speech": self.is_real_speech,
            "cached": self.cached,
            "synthesis_method": self.synthesis_method,
        }


def select_voice() -> str:
    listing = subprocess.run(
        ["say", "-v", "?"], capture_output=True, text=True, check=False, timeout=30
    )
    voices: list[tuple[str, str]] = []
    for line in listing.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].startswith(("zh_", "en_")):
            voices.append((parts[0], parts[1]))
    for preferred in PREFERRED_VOICE_NAMES:
        for name, locale in voices:
            if name == preferred and locale.startswith("zh_"):
                return name
    for name, locale in voices:
        if locale.startswith("zh_CN"):
            return name
    for name, locale in voices:
        if locale.startswith("zh_"):
            return name
    raise SpeechSynthesisError(
        "No Mandarin system voice is available; real-provider probes need "
        "understandable Chinese utterances."
    )


def _pcm_from_aiff(aiff_path: Path, wav_path: Path) -> bytes:
    conversion = subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1",
         str(aiff_path), str(wav_path)],
        capture_output=True, text=True, check=False, timeout=60,
    )
    if conversion.returncode != 0:
        raise SpeechSynthesisError(
            f"afconvert failed: {conversion.stderr.strip() or conversion.stdout.strip()}"
        )
    with wave.open(str(wav_path), "rb") as reader:
        if (reader.getframerate() != PCM_SAMPLE_RATE_HZ
                or reader.getnchannels() != PCM_CHANNELS
                or reader.getsampwidth() != PCM_SAMPLE_WIDTH_BYTES):
            raise SpeechSynthesisError(
                "Converted audio is not 24 kHz mono PCM16; the probes would reject it."
            )
        return reader.readframes(reader.getnframes())


def validate_raw_pcm(pcm_bytes: bytes) -> None:
    if len(pcm_bytes) == 0:
        raise SpeechSynthesisError("Synthesized PCM is empty.")
    if len(pcm_bytes) % PCM_SAMPLE_WIDTH_BYTES != 0:
        raise SpeechSynthesisError("Synthesized PCM is not a multiple of the sample width.")
    if pcm_bytes[:4] in (b"RIFF", b"FORM"):
        raise SpeechSynthesisError(
            "Synthesized audio still carries a container header; probes expect raw PCM."
        )


def synthesize_utterance(text: str, cache_dir: Path) -> UtteranceAudio:
    """Produce headerless 24 kHz mono PCM16 for `text` using system TTS."""
    if not text or not text.strip():
        raise SpeechSynthesisError("Utterance text must not be empty.")
    for tool in ("say", "afconvert"):
        if shutil.which(tool) is None:
            raise SpeechSynthesisError(f"Required system tool {tool!r} is unavailable.")
    cache_dir.mkdir(parents=True, exist_ok=True)
    voice = select_voice()
    digest = hashlib.sha256(f"{voice}\n{text}".encode("utf-8")).hexdigest()[:16]
    pcm_path = cache_dir / f"utterance-{digest}.pcm"
    if pcm_path.is_file() and pcm_path.stat().st_size > 0:
        pcm_bytes = pcm_path.read_bytes()
        validate_raw_pcm(pcm_bytes)
        return UtteranceAudio(
            text=text, pcm_path=pcm_path, byte_count=len(pcm_bytes),
            duration_seconds=len(pcm_bytes) / PCM_SAMPLE_WIDTH_BYTES / PCM_SAMPLE_RATE_HZ,
            voice=voice, is_real_speech=True, cached=True,
            synthesis_method="say+afconvert (cached)",
        )
    aiff_path = cache_dir / f"utterance-{digest}.aiff"
    wav_path = cache_dir / f"utterance-{digest}.wav"
    spoken = subprocess.run(
        ["say", "-v", voice, "-o", str(aiff_path), text],
        capture_output=True, text=True, check=False, timeout=120,
    )
    if spoken.returncode != 0 or not aiff_path.is_file():
        raise SpeechSynthesisError(
            f"say failed for voice {voice!r}: {spoken.stderr.strip() or spoken.stdout.strip()}"
        )
    pcm_bytes = _pcm_from_aiff(aiff_path, wav_path)
    validate_raw_pcm(pcm_bytes)
    pcm_path.write_bytes(pcm_bytes)
    aiff_path.unlink(missing_ok=True)
    wav_path.unlink(missing_ok=True)
    return UtteranceAudio(
        text=text, pcm_path=pcm_path, byte_count=len(pcm_bytes),
        duration_seconds=len(pcm_bytes) / PCM_SAMPLE_WIDTH_BYTES / PCM_SAMPLE_RATE_HZ,
        voice=voice, is_real_speech=True, cached=False,
        synthesis_method="say+afconvert",
    )


def synthesize_placeholder_for_self_tests(text: str, cache_dir: Path) -> UtteranceAudio:
    """Deterministic non-speech bytes for plumbing/self-tests only.

    Never valid evidence: the artifact is labeled `is_real_speech: false` and
    real runs refuse to proceed when system TTS is unavailable.
    """
    digest = hashlib.sha256(f"placeholder\n{text}".encode("utf-8")).hexdigest()[:16]
    cache_dir.mkdir(parents=True, exist_ok=True)
    pcm_path = cache_dir / f"placeholder-{digest}.pcm"
    pcm_bytes = bytes((index * 7) % 251 for index in range(PCM_SAMPLE_RATE_HZ // 4 * PCM_SAMPLE_WIDTH_BYTES))
    pcm_path.write_bytes(pcm_bytes)
    return UtteranceAudio(
        text=text, pcm_path=pcm_path, byte_count=len(pcm_bytes),
        duration_seconds=len(pcm_bytes) / PCM_SAMPLE_WIDTH_BYTES / PCM_SAMPLE_RATE_HZ,
        voice="<placeholder>", is_real_speech=False, cached=False,
        synthesis_method="runner placeholder (self-test only)",
    )
