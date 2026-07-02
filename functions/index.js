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
import functionsV1 from "firebase-functions/v1";
import admin from "firebase-admin";

admin.initializeApp();

// Per-user rate limit for analyzeShoe: max calls per rolling window. Fail-open
// (any error allows the request) so a limiter bug never blocks real analysis.
const RATE_LIMIT_MAX = 60;
const RATE_LIMIT_WINDOW_MS = 60 * 60 * 1000; // 1 hour

async function withinRateLimit(uid) {
  try {
    const ref = admin.firestore().collection("rateLimits").doc(uid);
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

const OPENAI_API_KEY = defineSecret("OPENAI_API_KEY");

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
{
  "overallCondition": "<one sentence: how worn overall>",
  "zoneNotes": "<bigToe: ...; lesserToes: ...; medialBall: ...; centralBall: ...; lateralBall: ...; medialMidfoot: ...; lateralMidfoot: ...; medialHeel: ...; centralHeel: ...; lateralHeel: ...>",
  "gaitType": "<neutral|pronation|supination|overpronation>",
  "wearZones": {
    "bigToe": "<green|yellow|orange|red>",
    "lesserToes": "<green|yellow|orange|red>",
    "medialBall": "<green|yellow|orange|red>",
    "centralBall": "<green|yellow|orange|red>",
    "lateralBall": "<green|yellow|orange|red>",
    "medialMidfoot": "<green|yellow|orange|red>",
    "lateralMidfoot": "<green|yellow|orange|red>",
    "medialHeel": "<green|yellow|orange|red>",
    "centralHeel": "<green|yellow|orange|red>",
    "lateralHeel": "<green|yellow|orange|red>"
  },
  "strikePattern": "<heel|midfoot|forefoot>",
  "primaryWearAreas": "<comma-separated most-worn zones>",
  "gaitCause": "<one sentence biomechanical cause referencing anatomy>",
  "concern": "<one sentence injury risk>",
  "severity": "<mild|moderate|severe>"
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

    // Per-user rate limit (fail-open) to guard against cost abuse.
    if (!(await withinRateLimit(uid))) {
      res.status(429).json({ error: "Too many requests. Please try again later." });
      return;
    }

    const { imageBase64, imageUrl, side, previousZones } = req.body || {};
    if (!side || (!imageBase64 && !imageUrl)) {
      res.status(400).json({ error: "Provide side and imageBase64 (or imageUrl)." });
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
          model: "gpt-4.1",
          messages: [
            {
              role: "user",
              content: [
                { type: "text", text: buildSingleShoePrompt(side, previousZones) },
                { type: "image_url", image_url: imageContent },
              ],
            },
          ],
          max_tokens: 2000,
          temperature: 0.1,
          response_format: { type: "json_object" },
        }),
      });

      if (!openaiRes.ok) {
        const errText = await openaiRes.text();
        res.status(502).json({ error: `OpenAI error: ${errText}` });
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
      res.status(500).json({ error: String(e?.message || e) });
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

  // Also clear any rate-limit record for this user.
  try {
    await admin.firestore().collection("rateLimits").doc(uid).delete();
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
