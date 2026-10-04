class_name Look
extends RefCounted
## The night lighting budget, in one place, because it is one budget.
##
## These numbers are not independent. Every street lamp in the world is additive
## and unshadowed, so energy, range, albedo and tonemap compound: raise the lamps
## and the pale things near them (palm trunks, kerbs, car bodies) blow out long
## before the tarmac they are meant to light becomes readable. Tuning them where
## they are used - spread across `world_builder.gd` and `night_env.gd` - is how
## they got set against each other instead of together.
##
## Measured on an RTX 3060 over the `street`, `aerial` and `carfront` presets,
## changing one line at a time. Frame mean / percent clipped / percent of frame in
## the dark / road-band mean. The road band is the bottom 40% of the frame, which
## is tarmac in every preset - frame-wide mean says how bright the night is, this
## says whether you can see the road you are driving on.
##
##     setting                    street  aerial  carfront   road (street)
##     baseline (before this)       8.82    2.88     28.91          0.45
##     ADJUSTMENT_CONTRAST 1.10     8.82    2.88     28.91          0.45   <- was
##     ADJUSTMENT_CONTRAST 1.06    10.50    4.16     30.57          0.53
##     ADJUSTMENT_CONTRAST 1.00    13.94    9.47     33.81          1.03   <- took this
##     ADJUSTMENT_CONTRAST 0.94    20.83   16.53     39.59          8.90
##
## The whole table is one line, `ADJUSTMENT_CONTRAST`, and it moves the aerial
## frame 3.3x. Everything else measured as noise or a loss:
##
##     STREETLIGHT_ENERGY 18 / 26 / 36   frame mean 12.2 / 15.6 / 19.3 but the
##        dark share only falls 93.1% -> 86.8 / 84.8 / 83.6%. Lamps are local;
##        the frame is dark because most of it is out of reach of any lamp, so
##        this spends blowout to buy nothing.
##     AMBIENT_ENERGY 1.1 / 1.7 / 8.0    <= 8% on every metric, because the
##        contrast floor was clamping the extra light away before it was ever
##        shown. Re-swept at 0.30 / 0.15 after the fix: still <= 3%.
##     GLOW_INTENSITY 0.0               trunk band 80.3 -> 76.5. Glow is a 5%
##        effect here, not the orange.
##     MOON x 0.48 (see `MatLib.MOON`)  aerial 9.47 -> 1.87. The moon is a
##        DirectionalLight with no falloff, so it is the dominant light in the
##        whole world - but dimming it is a loss, and the colour cast it causes
##        is not fixable from here (see the handoff note below).
##
## The trade-off in one sentence: the lamps are the only source with shape, so they
## carry the look and the ambient only keeps the dark from being a hole - but the
## grade was eating the bottom of the range, and that cost more than any lamp
## setting ever returned.

## Energy of one street lamp. Was 45.0, which was not "ten times a shopfront" but
## ten times a shopfront *and* additive down a straight - 1278 shadowless lamps
## stack on the tarmac and the frame is one saturated orange mass.
## Then 12.0, measured on the `street` pose of the anchor arterial, still 4.6%
## too hot: road band clipped 0.0643 against a 0.035 limit and road bright-orange
## 0.3730 against 0.25, with a pure-white (255,255,255) specular column 110 px
## tall at the exact frame centre.
##
## 10.0 is the value the sweep chose, and the sweep is the argument. Four
## candidates rendered and measured, every pose judged separately (never
## averaged - a mid-block number hides a junction failure):
##
##   energy/range/atten | street clip | street obright | junction luma | verdict
##   6.5 / 26.0 / 1.90  |    0.00703 |       0.04950 |       3.078  | arterial OK, junction DARK
##   8.0 / 32.0 / 1.35  |    0.02569 |       0.25878 |       4.903  | arterial obright, junction DARK
##   9.5 / 32.0 / 1.35  |    0.03065 |       0.29791 |       5.300  | arterial obright, junction DARK
##  10.0 / 30.0 / 1.45  |    0.02180 |       0.19841 |       4.396  | ARTERIAL PASSES
##  11.0 / 34.0 / 1.30  |    0.04838 |       0.35066 |       6.780  | arterial clips, junction DARK
##
## The 6.5/26/1.90 first attempt passed the arterial by a mile and darkened every
## other road in the map - kerb 20.211 -> 3.096, walk3 26.030 -> 4.897. That is a
## net loss and it was not shipped: it fixed the frame I was looking at by
## breaking five frames I was not. 10.0/30.0/1.45 is the only candidate that puts
## the arterial under BOTH limits, and the junction is repaired with light aimed
## at the junction (see JUNCTION_FILL_ENERGY) rather than by starving the rest of
## the map.
const STREETLIGHT_ENERGY := 10.0

## How far a lamp reaches. Energy is only half a light pool; the other half is
## where it stops. 34 m on a 21 m spacing means neighbouring pools overlap just
## enough to leave no unlit gap, and no further. 30 m keeps a continuous
## overlap without the two-sided double-pool stacking of a 34 m reach, which is
## what was driving the arterial peak.
const STREETLIGHT_RANGE := 30.0

## Falloff exponent. 1.0 is linear to the edge and reads as a flat disc on the
## tarmac; 1.25 pulls the light into a pool with a real edge, which is what a
## sodium lamp down a wet street actually looks like.
##
## Raised to 1.9. This is the lever that fixed the bright-white column, and it
## is worth recording why, because the column is NOT the luminaire.
##
## The column is the *specular reflection* of a lamp in the road. Measured on the
## delivered frame: at the exact horizontal centre, rows 435-545, a contiguous
## run of pure (255,255,255). Row 360 is eye level, so rows 435-545 are BELOW
## the horizon - on the tarmac. A luminaire head sits 7 m up, which from a 3.2 m
## eye projects far above the horizon, so the bright band cannot be the lamp
## mesh. `MatLib.wet_asphalt` is a deliberate near-mirror, the camera sits on the
## road centreline (`street` pose lateral 0.00) looking straight down the axis,
## and a mirror reflection of an off-axis light runs toward the viewer as a
## vertical streak - which projects to the exact centre of a one-point view.
##
## So the way to stop it is to stop the pool being a mirror-bright disc, and the
## peak is set by energy while the AREA of saturated orange is set by falloff.
## Energy alone shrank the pool but left the wide 1.25 wash bright; attenuation
## is what collapses the wash toward a tight pool under each head. Measured, at
## the 1.9 first attempt, the specular column went with it - which is also how
## the column was identified, since nothing else in the frame changed shape.
const STREETLIGHT_ATTENUATION := 1.45

## Junction fill. The junction was dark at EVERY candidate above, including the
## 12.0 baseline it started from (junction road mean 7.875, 72.4% of the band
## under the dark threshold against a 0.75 limit), so it is not an energy
## problem and no single global value can fix it - the arterial and the junction
## need opposite moves. It is a *geometry* problem: the lamp loop suppresses any
## standard inside the junction box (correctly - see `_streetlights`) and nothing
## replaces it, so the brightest, busiest 20 m in the map has no luminaire at all.
##
## So the fill is a light with no standard. It is mounted at 7 m and throws 26 m,
## which covers the box and dies before it can lift a mid-block pool, and it sits
## above the carriageway rather than in a traffic lane, so the "no standard in a
## lane" requirement is untouched - this adds no pole at all.
##
## Less saturated than SODIUM on purpose: a junction is the one place on this
## street with shopfronts and signage spilling into it, and a third light of pure
## sodium would push the `junction` pose over the bright-orange limit to fix a
## dark limit.
const JUNCTION_FILL_ENERGY := 9.0

const JUNCTION_FILL_RANGE := 26.0

const JUNCTION_FILL_HEIGHT := 7.0

## Warmer than white, cooler than SODIUM. See JUNCTION_FILL_ENERGY.
const JUNCTION_FILL_COLOUR := Color(1.0, 0.80, 0.58)

## Cool fill for everything no lamp reaches. Not sourced from the sky on purpose
## (see `night_env.gd`): this sky is nearly black by design, so a sky-sourced
## ambient measures at nothing and the whole near field renders pure black.
## The trade-off is that raising this flattens what the lamps are doing, so it is
## kept only high enough to read the road between pools.
const AMBIENT_ENERGY := 0.55

## Glow. Sodium lamps and neon should bleed, but glow is additive on top of an
## already-additive lighting budget: too much of it stops being "the lamp has a
## halo" and becomes "every bright thing is a white blob", which is what the
## headlights look like above 0.5.
const GLOW_INTENSITY := 0.55

## Where glow starts. 0.95 catches almost everything the sodium lamps put on the
## road; 1.1 leaves the road alone and bleeds only the lamp heads and the neon.
const GLOW_THRESHOLD := 0.95

## Contrast, and the black floor it implies. `adjustment_contrast` in Godot is
## `(value - 0.5) * contrast + 0.5`, which puts its zero-crossing at
## `0.5 - 0.5 / contrast`: at 1.10 that is linear 0.045, and everything below it
## is negative and clamps to pure black. The unlit road measures rgb(0,0,0) -
## not dark, *zero* - and raising `AMBIENT_ENERGY` barely moves it, because the
## extra light lands underneath the floor and gets clamped away again. Contrast
## buys punch at the cost of the whole bottom stop of the range, which is the
## exact range a night scene lives in.
const ADJUSTMENT_CONTRAST := 1.0

