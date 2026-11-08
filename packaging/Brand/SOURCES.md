# macOS application icon

`playbasis-mark-2048.png` is the original, transparent Playbasis **P** artwork from
the Playbasis brand library. It is the same blue-to-teal P used by the app's sidebar
brand mark, supplied at 2048 × 2048 pixels rather than enlarging the 192-pixel mark.

Run `./scripts/generate-app-icon.sh` to rebuild `packaging/AppIcon.icns` using
the macOS-native `sips` and `iconutil` tools. Every standard representation,
from 16 pixels to 1024 pixels, is generated from that original artwork and
checked by decoding the completed ICNS file. The build repeats this pipeline
into the signed application's resources, without changing source artwork.

The Playbasis name and marks are trademarks of Playbasis and are not covered by
any licence that may later be applied to the source code.
