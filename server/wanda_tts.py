"""Local text-to-speech with Kokoro (https://github.com/thewh1teagle/kokoro-onnx).

Model files live in server/tts_models/ (see README). The model is loaded on first use
and kept in memory; generation runs on the CPU, roughly 4x faster than real time on
Apple Silicon.
"""
import io
import os
import threading
import wave

import numpy as np

MODELS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tts_models")
MODEL_PATH = os.getenv("KOKORO_MODEL_PATH", os.path.join(MODELS_DIR, "kokoro-v1.0.onnx"))
VOICES_PATH = os.getenv("KOKORO_VOICES_PATH", os.path.join(MODELS_DIR, "voices-v1.0.bin"))

# Voice IDs start with a language letter and a gender letter, e.g. "af_heart".
LANGUAGES = {
    "a": ("en-us", "American English"),
    "b": ("en-gb", "British English"),
    "e": ("es", "Spanish"),
    "f": ("fr-fr", "French"),
    "h": ("hi", "Hindi"),
    "i": ("it", "Italian"),
    "j": ("ja", "Japanese"),
    "p": ("pt-br", "Brazilian Portuguese"),
    "z": ("cmn", "Mandarin Chinese"),
}
DEFAULT_VOICE = "af_nova"
# Wanda's default first, then the best-sounding voices by Kokoro's own ratings.
RECOMMENDED = [DEFAULT_VOICE, "af_heart", "af_bella", "bf_emma", "am_fenrir", "am_michael"]

_kokoro = None
_lock = threading.Lock()


class TTSUnavailable(Exception):
    pass


def _engine():
    global _kokoro
    with _lock:
        if _kokoro is None:
            if not (os.path.exists(MODEL_PATH) and os.path.exists(VOICES_PATH)):
                raise TTSUnavailable(
                    f"Kokoro model files not found in {MODELS_DIR}. See server/README.md."
                )
            from kokoro_onnx import Kokoro

            _kokoro = Kokoro(MODEL_PATH, VOICES_PATH)
        return _kokoro


def list_voices():
    voices = []
    for voice_id in _engine().get_voices():
        lang_code, lang_name = LANGUAGES.get(voice_id[0], ("en-us", "Other"))
        voices.append({
            "id": voice_id,
            "name": voice_id.split("_", 1)[-1].replace("_", " ").title(),
            "language": lang_code,
            "language_name": lang_name,
            "gender": "female" if voice_id[1:2] == "f" else "male",
            "recommended": voice_id in RECOMMENDED,
        })
    rank = {v: i for i, v in enumerate(RECOMMENDED)}
    return sorted(voices, key=lambda v: (rank.get(v["id"], len(rank)), v["id"]))


def synthesize(text: str, voice: str = DEFAULT_VOICE, speed: float = 1.0) -> bytes:
    """Returns 16-bit mono WAV audio for `text`."""
    kokoro = _engine()
    if voice not in kokoro.get_voices():
        raise ValueError(f"Unknown voice: {voice}")
    lang = LANGUAGES.get(voice[0], ("en-us", ""))[0]
    samples, sample_rate = kokoro.create(text, voice=voice, speed=min(max(speed, 0.5), 2.0), lang=lang)

    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2")
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm.tobytes())
    return buffer.getvalue()
