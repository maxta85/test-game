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
##
## ---------------------------------------------------------------------------
## RE-ANCHORED TO THE REAL GEOMETRY (street/grade-on-real-geometry)
##
## Everything above was measured over `./render.sh`'s `street`/`aerial`/`carfront`
## presets, which come from `Game/main.gd`'s `ShotPoser` and frame the grid
## **relative to the car** - so two runs are two different frames and "the grade
## improved" is not a measurable claim. The numbers below were re-measured on
## `World/look_dev_capture.gd`'s six fixed poses (`kerb`, `street`, `junction`,
## `walk1-3`), which are derived from `OSMLayout.start_line()` rather than from
## the car, on the same 359-junction / 401-edge OSM world the player drives. Same
## camera before and after, so the pairs are comparable and the frames are
## re-measurable without re-rendering.
##
##     godot --path . --rendering-driver vulkan --resolution 1280x720 \
##           --script res://World/look_dev_capture.gd -- --out /tmp/frames --tag X
##
## Two results from that re-measurement, both of which are *negative*, and both of
## which are here so the next person does not spend the day re-deriving them:
##
## **1. `GLOW_THRESHOLD` is not a hue lever, and the red-looking sky bloom is not
## a glow defect.** A sodium lamp's halo *looks* magenta-red against this city's
## blue night sky, which reads as a colour bug. It is not: subtract the sky
## behind it and the bloom's own colour is amber. The composite is the problem,
## not the glow. Sweeping the threshold over 0.95 / 0.55 / 0.30 / 0.12 moved the
## bloom's green-to-blue ratio 4.80 -> 4.23, i.e. very slightly the *wrong* way,
## so the apparent fix is worse than doing nothing. Measured on the `street`
## pose, bloom = pixel minus the median of an annulus containing no glow,
## core pixels (which carry no hue) excluded:
##
##     threshold   bloom rgb        g/b
##     0.95 (is)   191.2/ 71.6/14.9   4.80
##     0.55        192.2/ 74.8/16.5   4.52
##     0.30        192.6/ 77.4/17.7   4.36
##     0.12        193.5/ 79.1/18.7   4.23
##
## **2. The frame-clipping failure is emissive-source-bound, so no lamp setting
## can reach it.** `walk2` clips 4.37% of the frame against a 3.5% ceiling and no
## grade change moves it: the whole-frame clipped share is *bit-identical*
## (0.0437055) before and after a road-material change that moved every other
## pose. The clipped pixels are one building's glazing at rgb 249/249/251 -
## neutral white, 95% of a 290x35 region - i.e. an emissive panel clipping, not a
## surface catching a lamp. It comes from the `MatLib.emissive()` call sites in
## `World/osm_buildings.gd` (`WindowCool` at energy 2.0, `WindowWarm` 2.4,
## `SignFascia` 3.4), all of which exceed the tonemap's clip point at
## `tonemap_exposure` 1.45. Do **not** sweep `STREETLIGHT_ENERGY` chasing it:
## the junction road band already sits at 7.80 mean against a 6.0 floor, so
## there is 23% of headroom on that axis and spending it buys nothing here.
##
## The road itself was fixed at the material instead, in `World/mat_lib.gd`, and
## the clipped-highlight instrument that was missing from the hero surface is in
## `World/look_measure.gd` (`MAX_ROAD_CLIPPED`). No constant below changed value.
## ---------------------------------------------------------------------------

## Energy of one street lamp. Was 45.0, which was not "ten times a shopfront" but
## ten times a shopfront *and* additive down a straight - 1278 shadowless lamps
## stack on the tarmac and the frame is one saturated orange mass.
const STREETLIGHT_ENERGY := 12.0

## How far a lamp reaches. Energy is only half a light pool; the other half is
## where it stops. 34 m on a 21 m spacing means neighbouring pools overlap just
## enough to leave no unlit gap, and no further.
const STREETLIGHT_RANGE := 34.0

## Falloff exponent. 1.0 is linear to the edge and reads as a flat disc on the
## tarmac; 1.25 pulls the light into a pool with a real edge, which is what a
## sodium lamp down a wet street actually looks like.
const STREETLIGHT_ATTENUATION := 1.25

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

