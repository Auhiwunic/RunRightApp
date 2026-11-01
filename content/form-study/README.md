# Form Study — Gaita's IG content engine

A repeatable series that grows the Gaita account without ever saying "buy my
app." Each post takes a running clip, runs it through Gaita, and uses the app's
own analysis to explain **why** a runner's form is good (or what is holding them
back). The product sells itself by being the lens.

## Why this works
- It is **true**. Every number and target comes from the app's real biomechanics
  engine, not opinion. That is the whole brand.
- It is **native content**, not an ad. People follow accounts that teach them
  something. "Here is why this stride is efficient" is a teach, not a pitch.
- The app's visuals are **already cinematic**: the neon skeleton overlay, the
  your-run-vs-optimal gait curves, the cadence and ground contact callouts.
- It is **infinitely repeatable**. Any clip, any runner, same format.

## The pipeline (clip → post)
1. **Get a clip you have the rights to.** Film your own runs, film friends,
   license footage, or use clips with explicit reuse permission. Do NOT rip race
   broadcasts — copyright is a real risk even for "analysis."
2. **Run it through Gaita.** Upload the side on clip. Screen record the analysis:
   the skeleton overlay playing, the dials, the your-run-vs-optimal curves, the
   FOCUS cue grid.
3. **Pull the numbers.** Note the cadence, foot strike, ground contact, the one
   FOCUS insight. These are your script beats.
4. **Build the frames.** Open `frame-template.html`, edit the text for this
   runner, screenshot each 1080x1920 frame (or render with the script below).
5. **Cut the Reel.** Intercut: hook frame → clip with skeleton → metric callout
   frame → clip → takeaway frame. 20 to 40 seconds. Add captions.
6. **For AI b-roll / motion**, take the frames into Higgsfield (or CapCut) and
   animate. The frames are the anchor; the AI tool adds movement.
7. **Caption + post.** The caption template is in each episode script.

## Rendering frames to PNG (optional automation)
The template is plain HTML at exactly 1080x1920 per frame. To batch render:
```
# with Playwright installed (npm i -D playwright)
node render-frames.mjs
```
`render-frames.mjs` opens the template, screenshots each `.frame` div to
`out/frame-N.png`. Or just open the HTML in a browser and screenshot each frame
at a 1080x1920 viewport.

## Series rules (keep it consistent)
- One idea per post. Cadence, or foot strike, or hip drive. Never all three.
- Lead with the payoff in the first 2 seconds ("This is why elite runners barely
  touch the ground").
- Always show the app doing the analysis, never a static claim.
- Copy voice: plain, no hyphens, no em dashes, no hype adjectives. Let the
  numbers carry it.
- End on the principle, not the product ("quicker, lighter steps"), the same way
  the app's coach does.

## Files
- `frame-template.html` — the three branded 9:16 frame types, editable.
- `episode-01-cadence.md` — first full script + storyboard + caption.
- `biomechanics-reference.md` — the real target ranges to script from (pulled
  straight from the app), so every episode stays accurate.
