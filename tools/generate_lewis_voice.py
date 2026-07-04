#!/usr/bin/env python3
"""Render every Gaita coach cue with the Kokoro-82M Lewis voice (Apache 2.0).

Outputs AAC .m4a clips into RunRightApp/LewisVoice/, named by a slug that
mirrors LewisVoiceBackend.slug() exactly. Rerun whenever the cue copy in
VoiceAssistantMessageProvider.swift changes.

Requires: pip install kokoro-onnx soundfile, plus kokoro-v1.0.onnx and
voices-v1.0.bin (github.com/thewh1teagle/kokoro-onnx releases). afconvert
ships with macOS.
"""
import os, re, subprocess, sys, tempfile
import soundfile as sf
from kokoro_onnx import Kokoro

MODEL = sys.argv[1] if len(sys.argv) > 1 else "kokoro-v1.0.onnx"
VOICES = sys.argv[2] if len(sys.argv) > 2 else "voices-v1.0.bin"
OUT = os.path.join(os.path.dirname(__file__), "..", "RunRightApp", "LewisVoice")
VOICE, SPEED, LANG = "bm_lewis", 1.1, "en-gb"

FIXED_LINES = [
    # on pace
    "On target. Hold.",
    "Pace good. Steady.",
    "Locked in. Don't chase.",
    "Clean line. Keep it.",
    # slightly slow
    "Five down. Lift.",
    "Off pace. Quick feet, go.",
    "Losing time. Pick it up.",
    # slightly fast
    "Five quick. Ease off.",
    "Too hot. Settle.",
    "Ahead of plan. Back it down.",
    # too slow
    "Big gap. Push one minute, go.",
    "Well down. Commit or call it an easy day.",
    # too fast
    "Way hot. Back off now.",
    "Blowup pace. Ease. Trust the plan.",
    # starting out
    "And we're off. Easy first mile.",
    "Go steady. Target comes later.",
    # closing in
    "Final stretch. Hold form.",
    "Two hundred out. Quick feet, finish.",
    # finished
    "Done. Good stage.",
    "Stage complete. Strong work.",
    # mile split tails
    "Steady.",
    "Hold rhythm.",
    # struggling (kind, plain)
    "Pace is falling and effort is rising. Consider walking 60 seconds, then reset.",
    "Rough patch. Shorten your stride, slow your breath, and get through this mile.",
    "You're fighting it today. It's okay to drop pace and finish the run.",
    "Form is breaking down. Walk for 30 seconds, shake out your arms, jog again.",
    "Bad days happen. Completing the run at any pace still counts.",
    "If you can't hold planned pace, switch to effort-based running and call it done.",
    # gps weak
    "GPS signal is weak — pace coaching is paused until it stabilizes.",
    "Can't get a reliable pace right now. Keep running; I'll check back soon.",
    # provider fallback
    "Keep going — you're doing great.",
]

def slug(text: str) -> str:  # mirrors LewisVoiceBackend.slug()
    out, last_sep = [], True
    for ch in text.lower():
        if ch.isalnum():
            out.append(ch); last_sep = False
        elif not last_sep:
            out.append("_"); last_sep = True
    s = "".join(out).rstrip("_")
    return s[:120]

def main():
    os.makedirs(OUT, exist_ok=True)
    k = Kokoro(MODEL, VOICES)
    jobs = [(slug(t), t) for t in FIXED_LINES]
    jobs += [(f"mile_{n}", f"Mile {n}.") for n in range(1, 43)]
    for m in range(4, 20):
        for s in range(0, 60, 5):
            jobs.append((f"pace_{m}_{s:02d}", f"{m}:{s:02d} per mile."))
    print(f"{len(jobs)} clips -> {OUT}")
    for i, (name, text) in enumerate(jobs):
        dst = os.path.join(OUT, f"{name}.m4a")
        if os.path.exists(dst):
            continue
        samples, sr = k.create(text, voice=VOICE, speed=SPEED, lang=LANG)
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            sf.write(tmp.name, samples, sr)
            subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "48000",
                            tmp.name, dst], check=True, capture_output=True)
            os.unlink(tmp.name)
        if i % 25 == 0:
            print(f"  {i}/{len(jobs)} {name}")
    print("done")

if __name__ == "__main__":
    main()
