// Corsa — OpenAI shoe-wear analysis proxy.
//
// Keeps the OpenAI API key server-side so it never ships in the iOS binary.
// The app POSTs { imageBase64, side, previousZones? } with a Firebase ID token
// in the Authorization header; this function verifies the user, calls GPT-4o
// vision, and returns the SingleShoeResponse JSON the app already decodes.
//
// Deploy:
//   1. cd functions && npm install
//   2. firebase functions:secrets:set OPENAI_API_KEY   (paste your key)
//   3. firebase deploy --only functions,firestore:rules,storage
//   4. Put the printed function URL into the app's Info.plist as
//      SHOE_ANALYSIS_ENDPOINT, then delete OPENAI_API_KEY from Info.plist.

import { onRequest } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as functionsV1 from "firebase-functions/v1";
import admin from "firebase-admin";

admin.initializeApp();

// App Check on onRequest is NOT auto-enforced: unlike onCall (whose runtime
// verifies the token), the `enforceAppCheck` option on onRequest is only a
// deployment annotation and is a runtime no-op. So verify the attestation
// token ourselves. Returns true only for a request from the genuine app.
async function appCheckOk(req) {
  const token = req.get("X-Firebase-AppCheck");
  if (!token) return false;
  try {
    await admin.appCheck().verifyToken(token);
    return true;
  } catch (e) {
    return false;
  }
}

// Per-user rate limit for analyzeShoe: max calls per rolling window. Fail-open
// (any error allows the request) so a limiter bug never blocks real analysis.
const RATE_LIMIT_MAX = 60;
const RATE_LIMIT_WINDOW_MS = 60 * 60 * 1000; // 1 hour

async function withinRateLimit(uid, feature) {
  try {
    const ref = admin.firestore().collection("rateLimits").doc(`${uid}_${feature}`);
    return await admin.firestore().runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const now = Date.now();
      const data = snap.exists ? snap.data() : null;
      if (!data || now - (data.windowStart || 0) > RATE_LIMIT_WINDOW_MS) {
        tx.set(ref, { windowStart: now, count: 1 });
        return true;
      }
      if ((data.count || 0) >= RATE_LIMIT_MAX) return false;
      tx.update(ref, { count: (data.count || 0) + 1 });
      return true;
    });
  } catch (e) {
    return true; // fail-open
  }
}

// Only an https Firebase Storage URL may be forwarded to OpenAI as an image
// source; a raw user-supplied URL would be an SSRF-by-proxy (#17).
function isAllowedImageUrl(u) {
  try {
    const parsed = new URL(String(u));
    if (parsed.protocol !== "https:") return false;
    const host = parsed.hostname.toLowerCase();
    return host === "firebasestorage.googleapis.com"
      || host === "storage.googleapis.com"
      || host.endsWith(".firebasestorage.app");
  } catch (e) {
    return false;
  }
}

const OPENAI_API_KEY = defineSecret("OPENAI_API_KEY");

// The 10 sole zones every scan grades, in one place.
const SCAN_ZONES = [
  "bigToe", "lesserToes", "medialBall", "centralBall", "lateralBall",
  "medialMidfoot", "lateralMidfoot", "medialHeel", "centralHeel", "lateralHeel",
];

// Enforced output schema for the scan (strict structured outputs): the API
// itself rejects any response whose enums/types drift, so the client decoder
// never sees out-of-vocabulary values.
const SHOE_SCAN_SCHEMA = (() => {
  const zoneObject = (valueSchema) => ({
    type: "object",
    additionalProperties: false,
    required: SCAN_ZONES,
    properties: Object.fromEntries(SCAN_ZONES.map((z) => [z, valueSchema])),
  });
  return {
    type: "object",
    additionalProperties: false,
    required: [
      "overallCondition", "zoneNotes", "gaitType", "wearZones", "wearPercents",
      "strikePattern", "primaryWearAreas", "gaitCause", "concern", "severity",
      "estimatedMilesRemaining", "confidence", "treadNote",
    ],
    properties: {
      overallCondition: { type: "string" },
      zoneNotes: { type: "string" },
      gaitType: { type: "string", enum: ["neutral", "pronation", "supination", "overpronation"] },
      wearZones: zoneObject({ type: "string", enum: ["green", "yellow", "orange", "red"] }),
      wearPercents: zoneObject({ type: "integer" }),
      strikePattern: { type: "string", enum: ["heel", "midfoot", "forefoot"] },
      primaryWearAreas: { type: "string" },
      gaitCause: { type: "string" },
      concern: { type: "string" },
      severity: { type: "string", enum: ["mild", "moderate", "severe"] },
      estimatedMilesRemaining: { type: ["integer", "null"] },
      confidence: { type: "integer" },
      treadNote: { type: "string" },
    },
  };
})();

function buildSingleShoePrompt(side, previousZones) {
  const s = String(side || "").toUpperCase();
  const isLeft = String(side || "").toLowerCase() === "left";
  const medialSide = isLeft ? "LEFT" : "RIGHT";
  const lateralSide = isLeft ? "RIGHT" : "LEFT";

  let prompt = `You are a footwear-wear expert examining the SOLE (underside) of a SINGLE ${s} running shoe. Grade tread wear precisely. Accuracy matters more than speed.

ORIENTATION (critical): the sole faces the camera with the TOE at the TOP. For this ${s} shoe seen from the sole, the MEDIAL edge (big toe / arch / inner side) is on the ${medialSide} of the image and the LATERAL (outer) edge is on the ${lateralSide}. Map zones accordingly.

THE 10 ZONES: bigToe, lesserToes, medialBall, centralBall, lateralBall, medialMidfoot, lateralMidfoot, medialHeel, centralHeel, lateralHeel.

WEAR GRADES (judge actual tread/lug DEPTH and edge sharpness, not color or dirt):
- "green"  = like-new: deep lugs, crisp sharp edges, full texture
- "yellow" = used: grooves shallower or edges rounding, texture fading — ANY clear sign of use
- "orange" = worn: large flat/smooth patches, tread mostly gone there
- "red"    = bald: no tread left, smooth rubber, or foam/midsole showing through

FOR EACH ZONE: check whether lug/groove edges are sharp (new) or rounded/polished (worn); compare lug depth vs the least-used area (usually the arch). Grade by the zone's OVERALL condition, not its single worst pixel — if most of the zone still holds tread it is green/yellow, not orange/red. Ignore glare, reflections, dirt, and lighting; judge the tread itself.

CALIBRATION — be balanced: most used shoes are a MIX, mostly GREEN and YELLOW, with ORANGE only where tread is clearly flattened and RED only where tread is genuinely gone or foam shows. A typical moderately-used shoe has FEW or NO red zones. Do not over-grade. Equally, do not default everything to green — visibly rounding/shallow grooves are yellow. The midfoot/arch is usually least worn and rarely orange/red. Judge each zone independently and honestly.`;

  if (previousZones && typeof previousZones === "object") {
    const z = previousZones;
    prompt += `

PREVIOUS SCAN OF THIS SAME SHOE (baseline):
bigToe=${z.bigToe}, lesserToes=${z.lesserToes}, medialBall=${z.medialBall}, centralBall=${z.centralBall}, lateralBall=${z.lateralBall}, medialMidfoot=${z.medialMidfoot}, lateralMidfoot=${z.lateralMidfoot}, medialHeel=${z.medialHeel}, centralHeel=${z.centralHeel}, lateralHeel=${z.lateralHeel}

Rubber wear only progresses. Each zone must be the SAME or MORE worn than the baseline — never less. If the image looks less worn for a zone, output the baseline color.`;
  }

  prompt += `

Respond with ONLY this JSON object — no markdown, no text outside it.
Fill "zoneNotes" FIRST with what you actually observe per zone (forces you to look before grading).
Each wearZones value MUST be exactly one of: green, yellow, orange, red.
wearPercents is the SAME 10 zones as a precise 0-100 wear depth (0 = factory fresh, 100 = worn through). It MUST agree with the color: green 0-25, yellow 26-50, orange 51-75, red 76-100.
estimatedMilesRemaining: integer miles of useful life left across the whole shoe based on the worst load-bearing zones and visible midsole compression; null only if the photo truly cannot support an estimate.
confidence: 0-100 — how clearly the photo shows the tread (lighting, focus, angle, full sole visible).
treadNote: one sentence about tread depth and pattern condition (lugs, exposed midsole, smoothing).
{
  "overallCondition": "<one sentence: how worn overall>",
  "zoneNotes": "<bigToe: ...; lesserToes: ...; medialBall: ...; centralBall: ...; lateralBall: ...; medialMidfoot: ...; lateralMidfoot: ...; medialHeel: ...; centralHeel: ...; lateralHeel: ...>",
  "gaitType": "<neutral|pronation|supination|overpronation>",
  "wearZones": { "bigToe": "<green|yellow|orange|red>", ... all 10 zones ... },
  "wearPercents": { "bigToe": <0-100>, ... all 10 zones ... },
  "strikePattern": "<heel|midfoot|forefoot>",
  "primaryWearAreas": "<comma-separated most-worn zones>",
  "gaitCause": "<one sentence biomechanical cause referencing anatomy>",
  "concern": "<one sentence injury risk>",
  "severity": "<mild|moderate|severe>",
  "estimatedMilesRemaining": <integer or null>,
  "confidence": <0-100>,
  "treadNote": "<one sentence on tread depth and pattern>"
}`;

  return prompt;
}

export const analyzeShoe = onRequest(
  {
    secrets: [OPENAI_API_KEY],
    cors: true,
    timeoutSeconds: 120,
    memory: "512MiB",
    enforceAppCheck: true,
    invoker: "public",
  },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "Use POST." });
      return;
    }

    // Require a valid Firebase ID token so only signed-in users can call this.
    const authHeader = req.get("Authorization") || "";
    const idToken = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null;
    if (!idToken) {
      res.status(401).json({ error: "Missing auth token." });
      return;
    }
    let uid;
    try {
      const decoded = await admin.auth().verifyIdToken(idToken);
      uid = decoded.uid;
    } catch (e) {
      res.status(401).json({ error: "Invalid auth token." });
      return;
    }

    // Verify App Check ourselves (onRequest does not enforce it — see appCheckOk).
    if (!(await appCheckOk(req))) {
      res.status(401).json({ error: "App verification failed." });
      return;
    }

    // Per-user rate limit (fail-open) to guard against cost abuse.
    if (!(await withinRateLimit(uid, "scan"))) {
      res.status(429).json({ error: "Too many requests. Please try again later." });
      return;
    }

    const { imageBase64, imageUrl, side, previousZones } = req.body || {};
    if (!side || (!imageBase64 && !imageUrl)) {
      res.status(400).json({ error: "Provide side and imageBase64 (or imageUrl)." });
      return;
    }

    // Reject an imageUrl that isn't our own https Storage URL (#17).
    if (!imageBase64 && !isAllowedImageUrl(imageUrl)) {
      res.status(400).json({ error: "imageUrl must be an https Firebase Storage URL." });
      return;
    }

    const imageContent = imageBase64
      ? { url: `data:image/jpeg;base64,${imageBase64}`, detail: "high" }
      : { url: imageUrl, detail: "high" };

    try {
      const openaiRes = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${OPENAI_API_KEY.value()}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          // gpt-5.6-sol: OpenAI's flagship vision model (July 2026) — markedly
          // better fine-detail tread reading than gpt-4.1. Scans are metered
          // (5 free/month + rate limit), so the ~1 cent/scan cost is fine.
          model: "gpt-5.6-sol",
          messages: [
            {
              role: "user",
              content: [
                { type: "text", text: buildSingleShoePrompt(side, previousZones) },
                { type: "image_url", image_url: imageContent },
              ],
            },
          ],
          max_tokens: 3000,
          temperature: 0.1,
          // Enforced schema: enums and integer types are validated by the API,
          // so colors/gait/strike can never drift out of the app's vocabulary.
          response_format: {
            type: "json_schema",
            json_schema: { name: "shoe_scan", strict: true, schema: SHOE_SCAN_SCHEMA },
          },
        }),
      });

      if (!openaiRes.ok) {
        const errText = await openaiRes.text();
        console.error("Upstream OpenAI error", openaiRes.status, String(errText).slice(0, 500));
        res.status(502).json({ error: "This feature is temporarily unavailable. Please try again." });
        return;
      }

      const data = await openaiRes.json();
      const content = data?.choices?.[0]?.message?.content;
      if (!content) {
        res.status(502).json({ error: "No content from OpenAI." });
        return;
      }

      // Return the parsed SingleShoeResponse object directly.
      res.status(200).json(JSON.parse(content));
    } catch (e) {
      console.error("Handler error", String(e?.stack || e?.message || e).slice(0, 800));
      res.status(500).json({ error: "Something went wrong. Please try again." });
    }
  }
);

// Gaita coach chat proxy. The app POSTs { message, context, history } with a
// Firebase ID token; this verifies the user, grounds the model in the runner's
// real form/gait data and the drills library (all sent by the app in
// `context`), and returns { reply }. Key stays server-side, same as analyzeShoe.
export const coachChat = onRequest(
  {
    secrets: [OPENAI_API_KEY],
    cors: true,
    timeoutSeconds: 60,
    memory: "256MiB",
    enforceAppCheck: true,
    invoker: "public",
  },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "Use POST." });
      return;
    }

    const authHeader = req.get("Authorization") || "";
    const idToken = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null;
    if (!idToken) {
      res.status(401).json({ error: "Missing auth token." });
      return;
    }
    let uid;
    try {
      const decoded = await admin.auth().verifyIdToken(idToken);
      uid = decoded.uid;
    } catch (e) {
      res.status(401).json({ error: "Invalid auth token." });
      return;
    }

    // Verify App Check ourselves (onRequest does not enforce it — see appCheckOk).
    if (!(await appCheckOk(req))) {
      res.status(401).json({ error: "App verification failed." });
      return;
    }

    if (!(await withinRateLimit(uid, "coach"))) {
      res.status(429).json({ error: "Too many requests. Please try again later." });
      return;
    }

    const { message, context, history } = req.body || {};
    if (!message || typeof message !== "string" || message.length > 2000) {
      res.status(400).json({ error: "Provide a message under 2000 characters." });
      return;
    }

    const system = `You are Gaita, a running form coach inside the Gaita iOS app. Style: a rally co driver crossed with a good club coach. Direct, brief, specific, warm underneath. Keep replies under 120 words. Ground every answer in the runner's own data from the context JSON (formVideoAnalysis cue scores 0 to 100, gait type, strike pattern, focus insights) and recommend only drills that appear in the context drills list, with their dosage. CRITICAL DATA RULE: everything inside formVideoAnalysis was measured in a PAST recorded form video, not now. Its cadenceInThatVideo is the cadence in that clip, never the runner's current cadence. When asked about a CURRENT or live stat, use ONLY the liveRun object, which contains nothing but elapsed time, distance, and paces. If they ask for a live stat that is not in liveRun (cadence, heart rate, elevation, anything else), say plainly that you do not measure that live yet and, if useful, mention what the last form video showed, clearly labeled as from that video. Never present a stored or past number as a live one. Plain language. Never use hyphens, dashes, or bullet lists in replies, write flowing sentences. You give general fitness guidance, not medical advice: never diagnose, and if the runner mentions pain or injury, tell them to see a professional. Do not invent data that is not in the context. Your replies are read aloud by a voice, so write for the ear: spell out intervals and multipliers as words (say "four by 400 meters", never "4x400"), and never use a placeholder letter like X or Y in place of a value, always state the actual number.

YOU CAN ALSO TAKE ACTIONS on the runner's training plan. Set the "action" field. Days are "tomorrow", "today", or a weekday name like "saturday". Always fill all four fields (day, to, change) using null where not needed.
- Change a specific run or day (easier, harder, rest): {type:"adjust_day", day:<day>, to:null, change:<"easier"|"harder"|"rest">}.
- Move a run to a different day ("move my long run to Sunday"): {type:"move_run", day:<source day>, to:<target day>, change:null}. The source day becomes rest.
- Swap two days ("swap Tuesday and Thursday"): {type:"swap_days", day:<day A>, to:<day B>, change:null}.
- Change the WHOLE week ("make my week easier", "everything feels too hard"): {type:"adjust_week", day:null, to:null, change:<"easier"|"harder">}.
- Change their training profile, goals, days they can run, or weekly mileage: {type:"edit_profile", day:null, to:null, change:null}. Your reply says you will pull up the quick questions to rebuild their plan.
- Anything else (form questions, drills, encouragement): action null.
Only set an action when the runner is clearly asking to change their plan or profile. Your reply should confirm what you are doing in one short sentence when you set an action.

If the context contains a "liveRun" object, the runner is running RIGHT NOW: use its distanceMiles, elapsedSeconds, avgPaceSecPerMile, lastMilePaceSecPerMile and targetPaceSecPerMile to answer pace and distance questions directly (convert seconds to a m:ss per mile pace, so 465 becomes 7:45). If they are ahead of or behind targetPaceSecPerMile say so plainly. Never claim you lack their pace when liveRun is present. IMPORTANT: while liveRun is present you are coaching MID RUN, so NEVER set an action (do not adjust the plan, move runs, or rebuild the profile) — only give the runner their stats and a short in-the-moment tip. BREVITY IS CRITICAL MID RUN: they are breathing hard and listening, not reading. One short sentence is ideal, two short sentences is the absolute maximum, never more. No preamble, no sign off, just the answer. Set action to null.

RUNNER CONTEXT JSON:
${JSON.stringify(context || {}).slice(0, 6000)}`;

    const messages = [{ role: "system", content: system }];
    if (Array.isArray(history)) {
      for (const h of history.slice(-8)) {
        const role = h?.role === "user" ? "user" : "assistant";
        const text = String(h?.text || "").slice(0, 1000);
        if (text) messages.push({ role, content: text });
      }
    }
    // The app includes the latest user message in history; only append it if
    // it is not already the last turn.
    const last = messages[messages.length - 1];
    if (!(last && last.role === "user" && last.content === message)) {
      messages.push({ role: "user", content: String(message) });
    }

    try {
      const openaiRes = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${OPENAI_API_KEY.value()}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "gpt-4.1-mini",
          messages,
          max_tokens: 400,
          temperature: 0.6,
          response_format: {
            type: "json_schema",
            json_schema: {
              name: "coach_response",
              strict: true,
              schema: {
                type: "object",
                additionalProperties: false,
                required: ["reply", "action"],
                properties: {
                  reply: { type: "string" },
                  action: {
                    type: ["object", "null"],
                    additionalProperties: false,
                    required: ["type", "day", "to", "change"],
                    properties: {
                      type: { type: "string", enum: ["adjust_day", "move_run", "swap_days", "adjust_week", "edit_profile"] },
                      day: { type: ["string", "null"] },
                      to: { type: ["string", "null"] },
                      change: { type: ["string", "null"] },
                    },
                  },
                },
              },
            },
          },
        }),
      });

      if (!openaiRes.ok) {
        const errText = await openaiRes.text();
        console.error("Upstream OpenAI error", openaiRes.status, String(errText).slice(0, 500));
        res.status(502).json({ error: "This feature is temporarily unavailable. Please try again." });
        return;
      }

      const data = await openaiRes.json();
      const content = data?.choices?.[0]?.message?.content?.trim();
      if (!content) {
        res.status(502).json({ error: "No content from OpenAI." });
        return;
      }
      // Structured output: parse { reply, action }. Fall back to raw text if the
      // model ever returns plain text (older models / schema off).
      let parsed;
      try { parsed = JSON.parse(content); } catch { parsed = { reply: content, action: null }; }
      const reply = (parsed.reply || "").trim();
      if (!reply) {
        res.status(502).json({ error: "No content from OpenAI." });
        return;
      }
      res.status(200).json({ reply, action: parsed.action ?? null });
    } catch (e) {
      console.error("Handler error", String(e?.stack || e?.message || e).slice(0, 800));
      res.status(500).json({ error: "Something went wrong. Please try again." });
    }
  }
);

// Server-side account-data cascade. Fires when a Firebase Auth user is deleted
// (from the in-app "Delete Account" flow) and removes everything under
// users/{uid} in Firestore plus the user's Storage folder. This is the reliable
// backstop: the client wipe can be interrupted (app killed mid-delete), but this
// always runs once the auth user is gone, so no orphaned personal data remains.
export const onUserDeleted = functionsV1.auth.user().onDelete(async (user) => {
  const uid = user.uid;

  // Firestore: recursively delete the user's entire document subtree.
  try {
    await admin.firestore().recursiveDelete(
      admin.firestore().collection("users").doc(uid)
    );
  } catch (e) {
    console.error(`[onUserDeleted] Firestore wipe failed for ${uid}:`, e);
  }

  // Also clear this user's rate-limit records: the per-feature docs plus any
  // legacy single-doc record.
  try {
    const rl = admin.firestore().collection("rateLimits");
    await Promise.all([
      rl.doc(`${uid}_scan`).delete(),
      rl.doc(`${uid}_coach`).delete(),
      rl.doc(uid).delete(),
    ]);
  } catch (e) {
    console.error(`[onUserDeleted] rateLimit wipe failed for ${uid}:`, e);
  }

  // Storage: delete every file under users/{uid}/.
  try {
    await admin.storage().bucket().deleteFiles({ prefix: `users/${uid}/` });
  } catch (e) {
    console.error(`[onUserDeleted] Storage wipe failed for ${uid}:`, e);
  }
});
