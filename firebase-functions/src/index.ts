import * as functions from "firebase-functions";

// NOTE:
// - Deploy this function and set OPENAI_API_KEY securely via Firebase env/config.
// - The iOS app calls this function via `SHOE_ANALYSIS_ENDPOINT`.

function getOpenAIApiKey(): string | undefined {
  const fromEnv = process.env.OPENAI_API_KEY;
  // Firebase Functions config example:
  // functions.config().openai?.key
  const fromConfig = (functions.config() as any)?.openai?.key;
  return fromEnv || fromConfig;
}

async function fetchImageAsBase64(imageUrl: string): Promise<string> {
  const res = await fetch(imageUrl);
  if (!res.ok) {
    throw new Error(`Failed to fetch imageUrl: ${res.status} ${res.statusText}`);
  }
  const arrayBuffer = await res.arrayBuffer();
  return Buffer.from(arrayBuffer).toString("base64");
}

function buildSingleShoePrompt(side: string): string {
  return `
This image shows the SOLE (underside) of a SINGLE ${side.toUpperCase()} running shoe.

CAREFULLY examine the tread/rubber in each of these 10 zones and assign a wear color:

ZONES:
- bigToe: Big toe area (medial forefoot)
- lesserToes: Toes 2-5 area (lateral forefoot)
- medialBall: Inner ball of foot (1st metatarsal) — key pronation zone
- centralBall: Center ball (2nd-3rd metatarsal) — main push-off
- lateralBall: Outer ball (4th-5th metatarsal) — key supination zone
- medialMidfoot: Inner arch area
- lateralMidfoot: Outer midfoot
- medialHeel: Inner heel — pronation indicator at heel strike
- centralHeel: Center heel — main impact
- lateralHeel: Outer heel — first ground contact

COLOR RULES — focus on TREAD CONDITION:
- "green" = Full tread pattern visible, rubber looks new, sharp edges on tread grooves
- "yellow" = Tread pattern still visible but starting to smooth out, edges rounding off, any sign the shoe has been used
- "orange" = Tread pattern partially gone or very smooth, rubber noticeably worn down, flat patches where tread used to be
- "red" = Tread completely gone in this zone, smooth rubber, or foam/midsole showing through, no tread pattern remaining

CRITICAL RULES:
1. If you can see the tread pattern clearly with sharp grooves → "green"
2. If tread grooves are becoming shallow or rounded → "yellow"
3. If large areas have lost their tread pattern → "orange"
4. If there is NO tread left and you see flat/smooth rubber or exposed foam → "red"
5. When in doubt, pick the MORE worn color
6. Look at EACH zone independently — different zones wear at different rates

Also provide structured analysis fields (NO recommendations, NO paragraphs):
- strikePattern: Where the foot strikes first based on heel vs forefoot wear ("heel", "midfoot", or "forefoot")
- primaryWearAreas: Comma-separated list of the most worn zones (e.g. "Medial heel, central ball")
- gaitCause: ONE sentence explaining the biomechanical CAUSE of the detected gait type. Reference anatomy (arches, ankles, hips, tibialis posterior, etc). For overpronation mention collapsed arches or weak stabilizers. For supination mention high arches or tight lateral chain. For neutral just say balanced mechanics.
- concern: ONE sentence about injury RISK from this wear pattern. Do NOT include recommendations or advice.
- severity: How pronounced is the gait deviation — "mild", "moderate", or "severe". Neutral gait = "mild".

Respond in this EXACT JSON (no markdown, no extra text):
{
  "gaitType": "neutral|pronation|supination|overpronation",
  "wearZones": {
    "bigToe": "green",
    "lesserToes": "green",
    "medialBall": "green",
    "centralBall": "green",
    "lateralBall": "green",
    "medialMidfoot": "green",
    "lateralMidfoot": "green",
    "medialHeel": "green",
    "centralHeel": "green",
    "lateralHeel": "green"
  },
  "strikePattern": "heel",
  "primaryWearAreas": "Medial heel, central ball",
  "gaitCause": "One sentence biomechanical cause referencing anatomy.",
  "concern": "One sentence injury risk from this pattern.",
  "severity": "mild|moderate|severe"
}
`.trim();
}

function cleanModelContentToJson(content: string): string {
  return content
    .replace(/```json/g, "")
    .replace(/```/g, "")
    .trim();
}

export const analyzeSingleShoe = functions.https.onRequest(async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  try {
    const { imageUrl, side } = req.body ?? {};
    if (typeof imageUrl !== "string" || typeof side !== "string") {
      res.status(400).json({ error: "Missing required fields: imageUrl (string), side (string)" });
      return;
    }

    const apiKey = getOpenAIApiKey();
    if (!apiKey) {
      res.status(500).json({ error: "Missing OPENAI_API_KEY (set env/config for this function)" });
      return;
    }

    const base64Image = await fetchImageAsBase64(imageUrl);
    const prompt = buildSingleShoePrompt(side);

    const openAiResp = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-4o",
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: prompt },
              {
                type: "image_url",
                image_url: {
                  url: `data:image/jpeg;base64,${base64Image}`,
                  detail: "high",
                },
              },
            ],
          },
        ],
        max_tokens: 2000,
        temperature: 0.1,
      }),
    });

    if (!openAiResp.ok) {
      const text = await openAiResp.text();
      res.status(500).json({ error: "OpenAI call failed", details: text });
      return;
    }

    const json = await openAiResp.json();
    const content = json?.choices?.[0]?.message?.content;
    if (!content) {
      res.status(500).json({ error: "No content from model" });
      return;
    }

    const cleaned = cleanModelContentToJson(content);
    const parsed = JSON.parse(cleaned);
    res.status(200).json(parsed);
  } catch (err: any) {
    res.status(500).json({ error: "analyzeSingleShoe failed", details: err?.message ?? String(err) });
  }
});

