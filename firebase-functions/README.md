# Firebase Function: Shoe Analysis

This endpoint is the secure backend that replaces the hardcoded OpenAI key on-device.

## Endpoint
- Exported function: `analyzeSingleShoe`
- Method: `POST`
- Body JSON:
  - `imageUrl` (string): a Firebase Storage download URL
  - `side` (string): `"left"` or `"right"`

## OpenAI API key
Set the key securely for the function runtime:
- `OPENAI_API_KEY` environment variable, or
- Firebase Functions config key `functions.config().openai.key`

## iOS configuration
The app reads the function URL from `SHOE_ANALYSIS_ENDPOINT` in your app Info.plist / build settings.

It calls:
- `POST SHOE_ANALYSIS_ENDPOINT` with `{ imageUrl, side }`
and expects the response JSON to match `SingleShoeResponse`.

