# raft branding

The raft logo is a raft seen from above: four logs of uneven length, bound by two lashings. The
lashings are real holes in the shape, so the mark works on any background in one color, like the
Auk mark.

Colors and type are Auk's (`../../branding`): the mark in Deep `#12212b` on light pages and Ice
`#eef4f7` on dark ones, the wordmark "raft" in Familjen Grotesk 700.

## Files

| File | Use |
|---|---|
| `raft-logo-deep.svg` | the mark in Deep, transparent background (light pages) |
| `raft-logo-ice.svg` | the mark in Ice, transparent background (dark pages) |
| `raft-icon-light.svg` | app icon: Deep mark on an Ice rounded square |
| `raft-icon-dark.svg` | app icon: Ice mark on a Deep rounded square |
| `favicon.svg`, `favicon.ico` | browser tab icon (the `.ico` holds 16, 32 and 48 px) |
| `png/raft-logo-{deep,ice}-{512,1024}.png` | the mark as transparent PNGs |
| `png/raft-icon-{light,dark}-{16..1024}.png` | icons at 16, 32, 48, 64, 128, 180, 192, 256, 512 and 1024 px (180 = Apple touch icon, 192/512 = web app manifest) |

## Small sizes

At 48 px and below (the favicon and the 16, 32 and 48 px PNGs) the mark is a simpler drawing: three
thicker logs instead of four, wider lashings, and a little larger in its tile. The full drawing's
gaps close up at those sizes.

The registry site (rpm) uses `favicon.svg` and the mark in its header. The script that drew this
set, and the other options considered, are in rpm's `branding/` folder (`build_set.py`).
