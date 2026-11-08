# Skill tool portraits

Generated with the built-in image-generation tool, November 6, 2026, for Playbasis AI Agent Hub. Original art, no third-party logos or human identities. Contemporary precision-crafted objects; culturally neutral. These are decorative name-based categories, not evidence about a skill's work or quality.

Six 256×256 sRGB RGBA PNGs; under 350 KiB total. Visible long edge is 216 px, centered with transparent padding. Used at 30/40 pt with aspect-fit, no tint, no circle cropping, no extra shadows. A bounded six-image cache avoids repeated disk reads/decodes. Missing art has a system-glyph fallback. Providers stay separate. User overrides live in UserDefaults under skillPortrait.v1.<skill name>; Automatic clears the override. Refresh, usage and model changes cannot change automatic assignment.

`scripts/normalize-skill-portraits.swift` performs only deterministic alpha-bound normalization, sRGB conversion and downsampling, preserving aspect ratio and alpha. Artwork tests require actual transparent margins, meaningful consistent visible extent, square dimensions, cache reuse and a combined size below 1 MB.

## Exact generation prompt

Use case: stylized-concept. Production skill avatar PNG for Playbasis WorkspaceOps native macOS developer tool. Refined contemporary Japanese industrial-design sensibility, culturally neutral, high-end precision-crafted desk object portrait. Quiet minimalism, balanced negative space, tactile matte ceramic and finely satin anodized metal, subtle warm ivory and restrained desaturated accents. Sophisticated semi-realistic 3D editorial illustration, not photorealistic and not childish. One coherent object composition, centered on square canvas, near-orthographic three-quarter front view, soft broad top-left studio lighting, restrained contact shading within the object only. Object occupies about 78 percent of canvas longest dimension with generous safe margins. GENUINELY TRANSPARENT background and alpha channel, isolated cutout: NO circular disc, backdrop, base, platform, bounding tile, ground shadow or baked checkerboard. Must work on light and charcoal UI surfaces. No lettering, logos, faces, human hands, ornaments, cultural symbols, glow, glossy plastic, clutter or thin fragile details. Crisp anti-aliased edges. Subject: 

## Subject suffixes

- **research**: A precision magnifying lens with a thick satin muted teal metal rim and short handle, in front of a single warm ivory folded document. Bold readable lens silhouette.
- **build**: Three precisely interlocking matte blue-grey and warm ivory machined building blocks with one small brushed titanium connector. Clear architectural construction silhouette.
- **review**: A solid rounded sage ceramic shield with one large raised warm ivory check mark. One bold silhouette, precise chamfered edge.
- **design**: A fan of three thick matte material swatches in dusty coral, warm ivory and muted lavender, paired with one short graphite precision stylus. Clean bold composition.
- **release**: An elegant compact warm ivory ceramic rocket with muted teal anodized fins and one dark round porthole, pointing diagonally upwards. No flames, smoke, trail or particles.
- **knowledge**: An open thick ivory book with subtly curved blank pages, warm sand cloth cover and a single muted teal ribbon. Broad readable silhouette, no text.
