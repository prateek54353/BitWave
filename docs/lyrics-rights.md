# Lyrics Rights and Sharing

Bitwave allows users to export lyrics as shareable images. This feature is designed with respect for lyrics licensing and copyright.

## Implementation Details

- **4-line cap**: Users can select at most 4 consecutive lines from synced lyrics for sharing
- **Source attribution**: Each share card displays the lyrics source (e.g., "Source: LRCLIB")
- **Settings toggle**: The feature can be disabled entirely in Settings > Lyrics
- **User-controlled**: Only the user can initiate the share; no automated sharing occurs

## Important Notes for Release

Before releasing this feature to production, please review:

1. **Lyrics provider terms**: Verify that your lyrics provider's terms of service allow users to share limited excerpts (up to 4 lines) in visual form
2. **Fair use considerations**: 4-line excerpts may fall under fair use in some jurisdictions, but local laws vary
3. **Attribution requirements**: Ensure the source attribution on share cards meets any provider requirements
4. **License verification**: If using commercial lyrics providers, confirm your license covers user-generated shareable content

## Current Implementation

- Lyrics source displayed: LRCLIB (extend as additional providers are added)
- Maximum lines: 4 consecutive lines
- Share formats: PNG images (1:1 and 9:16 aspect ratios)
- Sharing method: System share sheet via share_plus
