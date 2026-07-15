//
//  OpenAIService.swift
//  RunRightApp
//

import Foundation
import FirebaseAuth
import FirebaseAppCheck
import UIKit

struct GaitAnalysisResponse: Codable {
    let shoeIdentification: ShoeIdentification?
    let leftFoot: FootAnalysis?
    let rightFoot: FootAnalysis?
    let overallGait: String?
    let overallConfidence: Int?
}

struct ShoeIdentification: Codable {
    let leftShoe: ShoeInfo?
    let rightShoe: ShoeInfo?
}

struct ShoeInfo: Codable {
    let brand: String
    let model: String
    let confidence: Int
    let identificationDetails: String?
}

/// 10-zone wear data based on biomechanical gait analysis regions
/// GPT returns a color string for each: "green", "yellow", "orange", or "red"
struct WearZoneData: Codable {
    var bigToe: String        // Hallux — medial push-off
    var lesserToes: String    // Toes 2-5 — lateral forefoot
    var medialBall: String    // 1st metatarsal head — KEY pronation indicator
    var centralBall: String   // 2nd-3rd metatarsal — primary push-off
    var lateralBall: String   // 4th-5th metatarsal — KEY supination indicator
    var medialMidfoot: String // Inner arch — high wear = flat foot/overpronation
    var lateralMidfoot: String // Outer midfoot
    var medialHeel: String    // Inner heel — pronation indicator at heel strike
    var centralHeel: String   // Center heel — primary heel strike
    var lateralHeel: String   // Outer heel — initial ground contact
    
    /// Flat dictionary of the 10 zones — used when sending a baseline to the backend.
    func toDictionary() -> [String: String] {
        [
            "bigToe": bigToe, "lesserToes": lesserToes,
            "medialBall": medialBall, "centralBall": centralBall, "lateralBall": lateralBall,
            "medialMidfoot": medialMidfoot, "lateralMidfoot": lateralMidfoot,
            "medialHeel": medialHeel, "centralHeel": centralHeel, "lateralHeel": lateralHeel
        ]
    }

    func color(for zone: String) -> String {
        switch zone {
        case "bigToe": return bigToe
        case "lesserToes": return lesserToes
        case "medialBall": return medialBall
        case "centralBall": return centralBall
        case "lateralBall": return lateralBall
        case "medialMidfoot": return medialMidfoot
        case "lateralMidfoot": return lateralMidfoot
        case "medialHeel": return medialHeel
        case "centralHeel": return centralHeel
        case "lateralHeel": return lateralHeel
        default: return "green"
        }
    }

    mutating func set(_ zone: String, _ colorValue: String) {
        switch zone {
        case "bigToe": bigToe = colorValue
        case "lesserToes": lesserToes = colorValue
        case "medialBall": medialBall = colorValue
        case "centralBall": centralBall = colorValue
        case "lateralBall": lateralBall = colorValue
        case "medialMidfoot": medialMidfoot = colorValue
        case "lateralMidfoot": lateralMidfoot = colorValue
        case "medialHeel": medialHeel = colorValue
        case "centralHeel": centralHeel = colorValue
        case "lateralHeel": lateralHeel = colorValue
        default: break
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bigToe = (try? container.decodeIfPresent(String.self, forKey: .bigToe)) ?? "green"
        lesserToes = (try? container.decodeIfPresent(String.self, forKey: .lesserToes)) ?? "green"
        medialBall = (try? container.decodeIfPresent(String.self, forKey: .medialBall)) ?? "green"
        centralBall = (try? container.decodeIfPresent(String.self, forKey: .centralBall)) ?? "green"
        lateralBall = (try? container.decodeIfPresent(String.self, forKey: .lateralBall)) ?? "green"
        medialMidfoot = (try? container.decodeIfPresent(String.self, forKey: .medialMidfoot)) ?? "green"
        lateralMidfoot = (try? container.decodeIfPresent(String.self, forKey: .lateralMidfoot)) ?? "green"
        medialHeel = (try? container.decodeIfPresent(String.self, forKey: .medialHeel)) ?? "green"
        centralHeel = (try? container.decodeIfPresent(String.self, forKey: .centralHeel)) ?? "green"
        lateralHeel = (try? container.decodeIfPresent(String.self, forKey: .lateralHeel)) ?? "green"
    }
    
    private enum CodingKeys: String, CodingKey {
        case bigToe, lesserToes
        case medialBall, centralBall, lateralBall
        case medialMidfoot, lateralMidfoot
        case medialHeel, centralHeel, lateralHeel
    }
}

struct FootAnalysis: Codable {
    let gaitType: String
    let confidence: Int
    let analysis: String
    let wearZones: WearZoneData?
}

/// Response for single-shoe analysis — wear zones + analysis text in one call
struct SingleShoeResponse: Codable {
    let gaitType: String            // "neutral" | "pronation" | "supination" | "overpronation"
    let wearZones: WearZoneData?
    let strikePattern: String?      // "heel" | "midfoot" | "forefoot"
    let primaryWearAreas: String?   // e.g. "Medial heel, central ball"
    let gaitCause: String?          // biomechanical cause referencing anatomy
    let concern: String?            // injury risk from this pattern
    let severity: String?           // "mild" | "moderate" | "severe"
    // Detailed fields (gpt-5.6 upgrade) — optional so older responses still decode.
    let wearPercents: [String: Int]?    // per zone, 0-100 wear depth
    let estimatedMilesRemaining: Int?   // useful life left, nil when unestimable
    let confidence: Int?                // 0-100 photo readability
    let treadNote: String?              // one sentence on tread depth/pattern

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A real analysis carries at least a gait type or wear zones. If neither
        // key is present the body isn't a shoe analysis (e.g. a backend error
        // object), so fail instead of fabricating a fake all-green result (#12).
        guard container.contains(.gaitType) || container.contains(.wearZones) else {
            throw OpenAIError.parseError
        }
        gaitType = (try? container.decode(String.self, forKey: .gaitType)) ?? "neutral"
        wearZones = try? container.decodeIfPresent(WearZoneData.self, forKey: .wearZones)
        strikePattern = try? container.decodeIfPresent(String.self, forKey: .strikePattern)
        primaryWearAreas = try? container.decodeIfPresent(String.self, forKey: .primaryWearAreas)
        gaitCause = try? container.decodeIfPresent(String.self, forKey: .gaitCause)
        concern = try? container.decodeIfPresent(String.self, forKey: .concern)
        severity = try? container.decodeIfPresent(String.self, forKey: .severity)
        wearPercents = try? container.decodeIfPresent([String: Int].self, forKey: .wearPercents)
        estimatedMilesRemaining = try? container.decodeIfPresent(Int.self, forKey: .estimatedMilesRemaining)
        confidence = try? container.decodeIfPresent(Int.self, forKey: .confidence)
        treadNote = try? container.decodeIfPresent(String.self, forKey: .treadNote)
    }

    private enum CodingKeys: String, CodingKey {
        case gaitType, wearZones, strikePattern, primaryWearAreas, gaitCause, concern, severity
        case wearPercents, estimatedMilesRemaining, confidence, treadNote
    }
}

class OpenAIService {
    static let shared = OpenAIService()

    /// Vision model used for wear analysis. gpt-5.6-sol (OpenAI's flagship
    /// vision model, July 2026) reads fine tread detail noticeably better than
    /// the gpt-4 family. Change in one place; keep in sync with functions/index.js.
    static let visionModel = "gpt-5.6-sol"

    /// Firebase HTTPS Cloud Function that holds the OpenAI key server-side.
    /// The app sends a Firebase ID token plus the single-shoe request body.
    private var endpoint: String {
        (Bundle.main.object(forInfoDictionaryKey: "SHOE_ANALYSIS_ENDPOINT") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://us-central1-corsa-51d8f.cloudfunctions.net/analyzeShoe"
    }
    
    private init() {}
    
    func analyzeShoeImage(_ image: UIImage, userPreferences: [String: String] = [:]) async throws -> GaitAnalysisResponse {
        throw OpenAIError.apiError(message: "Full-image shoe analysis is retired. Use the single-shoe scanner.")
    }
    
    /// Analyze a single shoe (left or right) for maximum accuracy
    func analyzeSingleShoe(_ image: UIImage, side: String, previousZones: WearZoneData? = nil) async throws -> SingleShoeResponse {
        // Tread wear is a fine, low-contrast texture — send max practical detail so
        // subtle and localized wear isn't lost to downscaling/compression.
        let resizedImage = resizeImage(image, maxDimension: 2048)

        guard let imageData = resizedImage.jpegData(compressionQuality: 0.92) else {
            throw OpenAIError.imageConversionFailed
        }
        debugLog("[OpenAI] image size: \(imageData.count / 1024) KB")

        var requestBody: [String: Any] = [
            "side": side,
            "imageBase64": imageData.base64EncodedString()
        ]
        if let previousZones {
            requestBody["previousZones"] = previousZones.toDictionary()
        }

        guard let url = URL(string: endpoint) else {
            throw OpenAIError.apiError(message: "Shoe analysis endpoint is not configured correctly.")
        }
        guard let idToken = try await Auth.auth().currentUser?.getIDToken() else {
            throw OpenAIError.apiError(message: "Please sign in and try again.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        // The backend enforces App Check (appCheckOk verifies X-Firebase-AppCheck
        // and 401s without it). The client MUST attach the attestation token or
        // every scan/coach call is rejected in production.
        if let appCheckToken = try? await AppCheck.appCheck().token(forcingRefresh: false) {
            request.setValue(appCheckToken.token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 45   // fail in 45s instead of 90s
        debugLog("[OpenAI] sending \(side) shoe request (\(request.httpBody!.count / 1024) KB)…")
        
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["error"] as? String {
                throw OpenAIError.apiError(message: msg)
            }
            let raw = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw OpenAIError.apiError(message: raw)
        }

        do {
            return try JSONDecoder().decode(SingleShoeResponse.self, from: data)
        } catch {
            debugLog("[OpenAI Single] Decode failed: \(error)")
            throw OpenAIError.parseError
        }
    }
    
    private func buildSingleShoePrompt(side: String, previousZones: WearZoneData? = nil) -> String {
        // Sole photos mirror the worn orientation — spell it out so the model
        // can't flip medial/lateral (a classic vision-model failure mode).
        let isLeftShoe = side.lowercased() == "left"
        let medialImageSide  = isLeftShoe ? "LEFT" : "RIGHT"
        let lateralImageSide = isLeftShoe ? "RIGHT" : "LEFT"

        var prompt = """
        You are a footwear-wear expert examining the SOLE (underside) of a SINGLE \(side.uppercased()) running shoe. Your job is to grade tread wear precisely. Accuracy matters more than speed.

        ORIENTATION (critical): the sole faces the camera with the TOE at the TOP. For this \(side.uppercased()) shoe seen from the sole, the MEDIAL edge (big toe / arch / inner side) is on the \(medialImageSide) of the image and the LATERAL (outer) edge is on the \(lateralImageSide). Map zones accordingly.

        THE 10 ZONES:
        - bigToe: Big toe (medial forefoot)
        - lesserToes: Toes 2-5 (lateral forefoot)
        - medialBall: Inner ball / 1st metatarsal — key pronation zone
        - centralBall: Center ball / 2nd-3rd metatarsal — main push-off
        - lateralBall: Outer ball / 4th-5th metatarsal — key supination zone
        - medialMidfoot: Inner arch
        - lateralMidfoot: Outer midfoot
        - medialHeel: Inner heel — key pronation zone
        - centralHeel: Center heel — main impact
        - lateralHeel: Outer heel — first ground contact

        WEAR GRADES (judge actual tread/lug DEPTH and edge sharpness, not color or dirt):
        - "green"  = like-new: deep lugs, crisp sharp groove edges, full texture
        - "yellow" = used: grooves visibly shallower or edges rounding, texture fading — ANY clear sign of use
        - "orange" = worn: large flat/smooth patches, tread mostly gone in that area
        - "red"    = bald: no tread left, smooth rubber, or foam/midsole showing through

        HOW TO DECIDE (do this for EACH zone before answering):
        1. Look at the lug/groove edges in that zone — are they sharp (new) or rounded/polished (worn)?
        2. Compare lug depth there vs the least-used part of the sole (usually the arch).
        3. Grade the zone by its OVERALL condition, not its single worst pixel. If most of the zone still holds tread, it is green or yellow — not orange/red.
        4. Ignore glare, reflections, dirt, and lighting — judge the tread itself.

        CALIBRATION — be balanced and realistic:
        - Most used running shoes are a MIX, mostly GREEN and YELLOW, with ORANGE only where tread is clearly flattened and RED only where tread is genuinely gone or foam shows through.
        - A typical moderately-used shoe has FEW or NO red zones. Do not paint a shoe mostly orange/red unless the tread is truly destroyed.
        - Equally, do not default everything to green: if grooves are visibly rounding or shallow, that zone is yellow.
        - Wear concentrates at the lateral heel and forefoot push-off; the midfoot/arch is usually the LEAST worn — it should rarely be orange/red.
        - Judge each zone independently and grade honestly between these extremes.

        ALSO determine (no advice, no paragraphs):
        - gaitType: neutral | pronation | supination | overpronation (from medial vs lateral wear balance)
        - strikePattern: heel | midfoot | forefoot (from heel vs forefoot wear)
        - primaryWearAreas: comma-separated most-worn zones
        - gaitCause: ONE sentence biomechanical cause referencing anatomy (arches, ankles, hips, tibialis posterior, etc.)
        - concern: ONE sentence injury risk (shin splints, plantar fasciitis, IT band, etc.)
        - severity: mild | moderate | severe (neutral gait = mild)

        """

        // Anchor to the previous scan: rubber wear only progresses, so any
        // "improvement" between scans is lighting/dirt noise — suppress it.
        if let z = previousZones {
            prompt += """


            PREVIOUS SCAN OF THIS SAME SHOE (use as your baseline):
            bigToe=\(z.bigToe), lesserToes=\(z.lesserToes), medialBall=\(z.medialBall), centralBall=\(z.centralBall), lateralBall=\(z.lateralBall), medialMidfoot=\(z.medialMidfoot), lateralMidfoot=\(z.lateralMidfoot), medialHeel=\(z.medialHeel), centralHeel=\(z.centralHeel), lateralHeel=\(z.lateralHeel)

            Rubber wear only progresses over time. For each zone, your color must be the SAME or MORE worn than the baseline — never less worn. If the image appears less worn than the baseline for a zone, output the baseline color (lighting and dirt differences are noise, not regrown tread).
            """
        }

        prompt += """


        Respond with ONLY this JSON object — no markdown, no text outside it.
        Fill "zoneNotes" FIRST: for every zone, write the few words you actually observe
        (e.g. "centralHeel: lugs polished flat") — this forces you to look before grading.
        Each wearZones value MUST be exactly one of: green, yellow, orange, red.

        {
          "overallCondition": "<one sentence: how worn is this shoe overall>",
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
        }
        """

        return prompt
    }
    
    /// Legacy multi-image narrative analysis is intentionally retired; the backend
    /// only supports the authenticated single-shoe path.
    func analyzeGaitPattern(leftImage: UIImage?, rightImage: UIImage?, leftZones: WearZoneData?, rightZones: WearZoneData?) async throws -> String {
        throw OpenAIError.apiError(message: "Gait narrative analysis is retired. Use the single-shoe scanner results.")
    }
    
    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return image }
        
        let ratio = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage ?? image
    }
    
    private func buildPrompt(preferences: [String: String]) -> String {
        return """
        You are an expert podiatrist and biomechanics specialist. Analyze the wear patterns on these running shoe soles in comprehensive detail.
        
        The image may contain BOTH left and right shoe soles. Analyze BOTH separately if visible.
        
        For each foot, analyze these RELIABLE indicators:
        
        1. **Wear Pattern Location & Intensity**:
           - Specific zones: Heel (medial/lateral/center), midfoot, ball of foot, forefoot, toes
           - Wear intensity: Light (minimal), Moderate (visible), Heavy (significant), Extreme (rubber worn through)
           - Exact edge identification: Medial (inner) vs Lateral (outer)
        
        2. **Strike Pattern** (highly reliable):
           - Heel striker: Heavy heel wear, light forefoot
           - Midfoot striker: Even heel-midfoot wear
           - Forefoot striker: Heavy forefoot/ball wear, light heel
        
        3. **Gait Type & Severity**:
           - Neutral, Pronation (mild/moderate/severe), Supination, Overpronation
           - Specify severity based on medial/lateral wear ratio
        
        4. **Structural Damage Assessment**:
           - Tread depth remaining (good/worn/gone)
           - Exposed midsole foam (white/colored foam visible through rubber)
           - Holes or tears in outsole
           - Midsole compression (creasing, flattening visible)
           - Heel counter breakdown
        
        5. **Interior/Upper Wear**:
           - Heel collar wear (Achilles contact area)
           - Interior medial/lateral side wear
           - Heel counter interior condition
           - Any visible interior damage
        
        6. **Terrain & Surface Analysis**:
           - Road running: Even, consistent wear patterns
           - Trail running: Uneven wear, rock impact marks, aggressive tread wear
           - Track: Very even, symmetrical wear
           - Treadmill: Uniform wear, often less severe
        
        7. **Replacement Urgency** (be specific):
           - Immediate: Exposed midsole, holes, complete tread loss in critical zones
           - Soon (50-100 miles): Heavy wear, significant tread loss, visible compression
           - Moderate (100-200 miles): Moderate wear, some tread remaining
           - Still good (200+ miles): Light wear, good tread depth
        
        8. **Left vs Right Comparison**:
           - Percentage difference in wear severity
           - Which foot shows more wear
           - Implications of asymmetry
        
        DO NOT attempt to identify the shoe brand or model.
        DO NOT include confidence percentages or scores.
        DO NOT guess runner's weight or exact mileage.
        
        9. **Wear Zone Color Grid** (CRITICAL — based on biomechanical gait regions):
           The shoe sole is divided into 10 zones that follow the actual gait cycle.
           
           GAIT CYCLE ZONES (top to bottom):
           - bigToe: The big toe (hallux) area — medial forefoot, used during push-off
           - lesserToes: Toes 2-5 area — lateral forefoot
           - medialBall: 1st metatarsal head (inner ball) — KEY pronation indicator during push-off
           - centralBall: 2nd-3rd metatarsal heads (center ball) — primary push-off zone
           - lateralBall: 4th-5th metatarsal heads (outer ball) — KEY supination indicator
           - medialMidfoot: Inner arch/midfoot — high wear here = flat foot or overpronation
           - lateralMidfoot: Outer midfoot — normal contact area
           - medialHeel: Inner heel — pronation indicator at heel strike
           - centralHeel: Center heel — primary heel strike impact zone
           - lateralHeel: Outer heel — initial ground contact point (first to touch)
           
           For each zone, assign EXACTLY one color. Use LOW thresholds — be aggressive:
           - "green" = ONLY if the zone looks absolutely brand new, untouched, factory fresh with zero signs of any use whatsoever
           - "yellow" = the slightest hint of use — any smoothing, any minor tread change, any difference from brand new
           - "orange" = any noticeable wear — tread visibly reduced, rubber showing use, smoothed patches
           - "red" = moderate to heavy wear — clear tread loss, rubber thinning, any worn-through areas
           
           CRITICAL: Most zones on a used shoe should be "yellow" or higher. "green" should be RARE — only for zones that look completely untouched. If in doubt between two colors, ALWAYS pick the more worn one. A shoe that has been run in even once should have almost no "green" zones.
           Analyze LEFT and RIGHT foot SEPARATELY — they often differ.
        
        Respond in this EXACT JSON format (no markdown):
        {
          "shoeIdentification": null,
          "leftFoot": {
            "gaitType": "neutral|pronation|supination|overpronation",
            "confidence": 0,
            "analysis": "COMPREHENSIVE ANALYSIS...",
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
            }
          },
          "rightFoot": {
            "gaitType": "neutral|pronation|supination|overpronation",
            "confidence": 0,
            "analysis": "COMPREHENSIVE ANALYSIS...",
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
            }
          },
          "overallGait": "COMPREHENSIVE SUMMARY...",
          "overallConfidence": 0
        }
        
        IMPORTANT: Each wearZones value MUST be exactly "green", "yellow", "orange", or "red". These directly color a heatmap. Be accurate to what you SEE in each specific anatomical zone.
        
        Be highly specific with measurements and observations. Use precise terminology. Focus on actionable insights.
        """
    }
    
    private func parseResponse(from content: String) throws -> GaitAnalysisResponse {
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let data = cleaned.data(using: .utf8) else {
            throw OpenAIError.parseError
        }
        
        // Try full decode first
        do {
            return try JSONDecoder().decode(GaitAnalysisResponse.self, from: data)
        } catch {
            debugLog("[OpenAI Parse] Full decode failed: \(error)")
            debugLog("[OpenAI Parse] Raw JSON:\n\(cleaned)")
        }
        
        // Fallback: try to decode without wearZones by using a lenient model
        // This keeps the text analysis working even if zone data is malformed
        do {
            let fallback = try JSONDecoder().decode(GaitAnalysisResponseFallback.self, from: data)
            return GaitAnalysisResponse(
                shoeIdentification: fallback.shoeIdentification,
                leftFoot: fallback.leftFoot.map { FootAnalysis(gaitType: $0.gaitType, confidence: $0.confidence, analysis: $0.analysis, wearZones: nil) },
                rightFoot: fallback.rightFoot.map { FootAnalysis(gaitType: $0.gaitType, confidence: $0.confidence, analysis: $0.analysis, wearZones: nil) },
                overallGait: fallback.overallGait,
                overallConfidence: fallback.overallConfidence
            )
        } catch {
            debugLog("[OpenAI Parse] Fallback decode also failed: \(error)")
            throw OpenAIError.parseError
        }
    }
}

// Fallback model that ignores wearZones entirely
private struct GaitAnalysisResponseFallback: Codable {
    let shoeIdentification: ShoeIdentification?
    let leftFoot: FootAnalysisFallback?
    let rightFoot: FootAnalysisFallback?
    let overallGait: String?
    let overallConfidence: Int?
}

private struct FootAnalysisFallback: Codable {
    let gaitType: String
    let confidence: Int
    let analysis: String
    // wearZones intentionally omitted so decoding never fails on it
}

private struct OpenAIResponse: Codable {
    let choices: [Choice]
}

private struct Choice: Codable {
    let message: Message
}

private struct Message: Codable {
    let content: String
}

enum OpenAIError: LocalizedError {
    case imageConversionFailed
    case apiError(message: String)
    case missingApiKey
    case noContent
    case parseError
    
    var errorDescription: String? {
        switch self {
        case .imageConversionFailed: return "Failed to process image"
        case .apiError(let msg): return "API Error: \(msg)"
        case .missingApiKey: return "Shoe analysis endpoint is not configured. Deploy the Firebase analyzeShoe function and set SHOE_ANALYSIS_ENDPOINT."
        case .noContent: return "No analysis received"
        case .parseError: return "Failed to parse results"
        }
    }
}
