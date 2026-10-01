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
## Measured on an RTX 3060 over the `street` and `carfront` presets, changing one
## line at a time, frame mean / p99 / percent clipped / percent of frame in the
## dark / percent of frame reading as sodium orange:
##
##     SWEEP TABLE FILLED IN FROM MEASURED RENDERS - see below.
##
## The trade-off in one sentence: the lamps are the only source with shape, so they
## carry the look and the ambient only keeps the dark from being a hole.

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
