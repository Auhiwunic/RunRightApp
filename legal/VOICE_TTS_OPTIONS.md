# On-Device Voice (TTS) Options for Gaita

**Goal:** replace/supplement the ElevenLabs cloud voice coach with an **open-source, on-device** text-to-speech engine whose voice model is **bundled (pre-downloaded) inside the app**, so coaching cues are generated **fully offline** — no per-call cloud cost, no coaching text leaving the device, and it works with no signal mid-run.

> Findings below were researched against current sources and **adversarially verified**. License notes are factual, not legal advice — have counsel confirm before release. **The #1 trap in this whole space:** a model's *code* license and its *voice-weights* license are often different, and most neural voices secretly depend on the **espeak-ng** phonemizer, which is **GPLv3** — copyleft that is widely considered incompatible with closed-source App Store distribution. Every recommendation below is chosen to avoid that trap.

---

## TL;DR recommendation

**Runtime (the engine):** [**sherpa-onnx**](https://github.com/k2-fsa/sherpa-onnx) (k2-fsa) — **Apache-2.0**, runs ONNX voices fully on-device, has an official iOS Swift/SwiftUI TTS example, min iOS 13. This is the layer; you then pick a bundled voice.

**Bundled voice — pick one:**

| Option | License (code + weights) | Quality | Bundle size (verified) | espeak-ng/GPL? | Verdict |
|---|---|---|---|---|---|
| **MeloTTS-English** (via sherpa-onnx) | MIT + MIT | Natural | **~170 MB** (ships in a bilingual zh_en pack) | **No** (lexicon/FST) | ✅ **Primary pick** — cleanest natural voice |
| **VITS-ljspeech** (via sherpa-onnx) | MIT/Apache + public-domain | Decent | **~109 MB** | **No** (lexicon) | ✅ **Safest** — fully clean, smaller, slightly dated voice |
| **Kokoro-82M** (ONNX or CoreML) | Apache-2.0 weights | **Very natural (best)** | ~80 MB (int8/CoreML) – ~310 MB (fp32) | **Yes by default** ⚠️ | ⚠️ Best quality, **only if** you swap espeak-ng for a permissive G2P (misaki / OpenPhonemizer / FluidAudio BART) |

**Always-on fallback:** **Apple `AVSpeechSynthesizer`** — free, on-device, zero bundle size, already wired into your `CompositeSpeechBackend`. Keep it as the last-resort voice.

**Suggested architecture for Gaita:**
```
CompositeSpeechBackend:
  1. SpeechAudioCache         (already exists — cached phrases)
  2. SherpaOnnxSpeechBackend  (NEW — bundled MeloTTS/ljspeech, default offline voice)
  3. AVSpeechBackend          (already exists — free system fallback)
  4. CloudTTSSpeechBackend    (already exists — optional ElevenLabs "premium online voice", opt-in)
```
This slots cleanly into your existing `SpeechBackend` protocol — you're adding one backend, not rebuilding the coach.

---

## Recommended stack in detail

### Runtime: sherpa-onnx (Apache-2.0) ✅ verified
- Engine code is genuinely Apache-2.0 (commercial App Store use fine, no copyleft on your app).
- Official iOS path: `sherpa-onnx.xcframework` + onnxruntime via the `build-ios` output (bridging header) **or** the community SwiftPM binary package `willwade/sherpa-onnx-spm`.
- Reference app to copy: [`ios-swiftui/SherpaOnnxTts/ViewModel.swift`](https://github.com/k2-fsa/sherpa-onnx/blob/master/ios-swiftui/SherpaOnnxTts/SherpaOnnxTts/ViewModel.swift) — set up `OfflineTtsConfig`, bundle the model files in the app target, call `generate(text:speakerId:speed:)` → PCM → play via `AVAudioPlayer`/`AVAudioEngine`.
- **Watch-out (verified):** the sherpa-onnx model *archives* for Piper/Kokoro bundle `espeak-ng-data` (GPLv3). Choosing MeloTTS or ljspeech avoids this because they phonemize via a bundled `lexicon.txt` + FST, **not** espeak-ng.

### Primary voice: MeloTTS-English ✅ verified clean (size corrected)
- **MIT** code *and* weights; phonemization is lexicon-based → **no espeak-ng**, so the whole stack stays MIT/Apache.
- CPU real-time for short phrases like *"Mile 3, pace 8:30, keep it steady."* Naturalness rated at or above Piper.
- **Size reality check (verification corrected the estimate):** the `model.onnx` alone is ~163 MB; with lexicon + tokens + 3 FSTs the bundle is **~170 MB**, not the 80–110 MB first estimated. The released English voice ships **inside the bilingual `vits-melo-tts-zh_en` package** (Chinese + English), so you bundle the whole thing. Budget ~170 MB and confirm it's acceptable for your app download size.
- Sources: [MeloTTS](https://github.com/myshell-ai/MeloTTS) · [LICENSE](https://github.com/myshell-ai/MeloTTS/blob/main/LICENSE) · [sherpa-onnx models](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/index.html)

### Safest / smaller voice: VITS-ljspeech ✅ fully verified clean
- Verified clean across **all three layers**: runtime Apache-2.0, weights MIT (jaywalnut310/vits) / Apache mirror, training data (LJ Speech) public domain. Lexicon-based → no espeak-ng. **No license traps found.**
- ~109 MB, single-speaker, "decent" but somewhat dated voice.
- Use this if MeloTTS's size or zh_en packaging bothers you and you can accept slightly lower naturalness. Source: [sherpa-onnx VITS](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/vits.html)

### Best quality (with a caveat): Kokoro-82M ⚠️ verified
- Weights are genuinely **Apache-2.0** (verified on [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M)); top-ranked small model; proven CoreML/ANE pipeline (~45 ms warm, 12–79× real-time on Apple silicon); 11+ English voices.
- **Caveat (verified):** its default grapheme-to-phoneme is **espeak-ng (GPLv3)**, and sherpa-onnx's Kokoro archive bundles `espeak-ng-data`. To ship commercially you **must** replace the G2P with a permissive one — e.g. **misaki**, **OpenPhonemizer**, or a CoreML build using **FluidAudio's BART G2P** ([FluidInference/kokoro-82m-coreml](https://huggingface.co/FluidInference/kokoro-82m-coreml)). Do that and it's the best-sounding bundleable option.

### Free fallback: Apple AVSpeechSynthesizer ✅ (already in app)
- Free, fully on-device, zero bundle size, zero license risk. Default voices sound robotic; the good "enhanced/premium"/Personal Voice tiers **cannot be bundled or guaranteed** (user must download ~100–500 MB via Settings, no API to trigger it). So it's the perfect *fallback*, not your guaranteed-quality voice — which is exactly how Gaita uses it today.

---

## What to avoid (and why) — verified

| Engine | Why not |
|---|---|
| **Coqui XTTS-v2** | Weights are **Coqui Public Model License = NON-commercial**, and Coqui is defunct so you can't buy a commercial license. Also too big/slow for on-device. ❌ |
| **Parler-TTS** | Cleanly Apache-2.0, but it's an autoregressive transformer — **too heavy/slow** for real-time on iPhone, no ONNX/CoreML iOS path. ❌ |
| **Piper (default)** | The `.onnx` voice can be fine, but distributed Piper relies on **espeak-ng (GPLv3)**, and some voices (Blizzard/lessac) are **research-only**. Only viable if you strip espeak-ng **and** use a CC-BY voice (LibriTTS-R). MeloTTS/ljspeech are cleaner. ⚠️ |
| **eSpeak-NG** | **GPL-3.0** copyleft trap for a closed App Store app; also openly robotic. (It's useful only as a phonemizer — which is the trap.) ❌ |
| **RHVoice** | No iOS port; de-facto GPL-3.0 build (MAGE/HTS); some voices non-commercial. ❌ |
| **Festival / MaryTTS** | No viable iOS path (desktop/server; MaryTTS is pure Java — no JVM on iOS). ❌ |
| **Flite / Mimic 1** | Cleanly permissive (BSD) and tiny (~2 MB), but **robotic** — doesn't beat the free Apple default, so no reason to bundle. ➖ |

---

## Implementation notes for Gaita

1. Add `sherpa-onnx` via SwiftPM (`willwade/sherpa-onnx-spm`) or the xcframework build.
2. Bundle the chosen voice's files (`model.onnx`, `tokens.txt`, `lexicon.txt`, FSTs) in the app target. **Do not bundle `espeak-ng-data`** — that's the GPL trap; MeloTTS/ljspeech don't need it.
3. Create `SherpaOnnxSpeechBackend: SpeechBackend` mirroring `AVSpeechBackend` — synthesize to PCM, play through your existing `AudioPlaybackController`.
4. Insert it into `CompositeSpeechBackend` ahead of `AVSpeechBackend` and behind the cache.
5. Keep `CloudTTSSpeechBackend` (ElevenLabs) as an **opt-in** "premium online voice" toggle — and update the Privacy Policy's voice-coach section accordingly (if the bundled voice becomes the default, the coach is offline by default and the cloud disclosure becomes opt-in only). See `legal/PRIVACY_POLICY.md`.
6. For any **CC-BY** voice (if you ever use a Piper LibriTTS-R voice) add an attribution line in an in-app acknowledgements screen.
7. Verify real-time factor (RTF) on your **minimum** target iPhone before shipping.
