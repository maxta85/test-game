# ART DIRECTION — CAIRNS AFTER DARK

Written by the lead after looking at the reference boards (Midnight Club 3D,
Tokyo Xtreme, Forza). This is the look we are building toward, and it is a
*deliberate reversal* of the "hot orange tropical night" that was the first
instinct. Read it before you add a light, a material or a building.

## The one-line version

**A wet, dark, cool night where colour comes from light sources, not from the
air.** The reference images are mostly black. What you see is bright small
sources — sodium lamps, shopfronts, neon, headlights — smeared down a mirror
road, with a few saturated signs doing the talking.

## What we had wrong

The first pass made the *fog* the subject: a thick warm orange haze that lit
everything evenly from behind. It produced a single-hue orange frame, no
contrast, black roads, and no readable car. Fog should be the thing that makes a
*beam* visible, never the thing that lights the scene. If a change makes the air
brighter without making a light source brighter, it is wrong.

## Palette

| Role | Colour | Where |
|---|---|---|
| Base night | `#0a0d16` deep blue-black | sky, unlit surfaces, ambient shadow |
| City glow | `#1a2438` cool | low on the horizon only, behind the skyline |
| Sodium | `#ffa03d` warm amber | streetlights, the warm/cool contrast that sells the street |
| Mercury / shopfront | `#b8d4ff` cool white | shop windows, floodlights, car yards |
| Neon accents | cyan `#33e0e0`, magenta `#ff3d7a`, red `#ff2d2d` | signage only, and sparingly |
| Tail lights | `#ff1a0a` | every car, always on, brighter under braking |
| Headlights | `#fff2d8` | every car, always on |

Rule: **saturated colour is a light source, not a surface.** Nothing in the world
is painted bright cyan. If a surface needs to read as a colour, it is emitting.

## The road is the hero surface

Wet asphalt: roughness 0.10–0.18, metallic specular 1.0, a broken-up roughness
noise so reflections are streaky rather than a sheet of plastic. Screen-space
reflections on. The reflection probe follows the player. If a render does not
have long vertical smears of light down the tarmac, it is not finished — that
smear is what the whole genre is built on.

## Contrast, not brightness

Raise a light's *energy* and lower the *ambient*. Our failure mode is lifting
everything until nothing has a silhouette. Rules of thumb:

- ambient energy low enough that an unlit kerb is nearly black
- every lamp a small, bright, saturated point — not a wide dim wash
- volumetric fog density low (0.008–0.015), emission low, purely to catch beams
- glow on, threshold high, so only genuinely bright things bloom

## The car is the hero object

You are looking at the back of a car for most of the game. It must read in
silhouette: distinct roofline, visible wheels, a spoiler or boot line, paint
that catches a highlight, headlights throwing a cone down the road, tail lights
glowing, brake lights flaring when you brake. A car with no lights is a hole in
the frame.

## City depth

Manunda is low-rise, so it needs a horizon. A distant CBD silhouette — a band of
boxes at 1.5–2 km with emissive window grids, some with beacons — gives the sky
a floor and makes the suburb read as part of a city. Cairns has a real CBD; the
skyline is honest to the place.

## HUD

Thin, corner-anchored, and never in the middle of the road:

- top-left: lap, race time, wrong-way
- top-right: position, standings, cash
- bottom-left: minimap (or a street/route hint)
- bottom-right: speed, gear, rev bar
- centre: only the countdown, and only while it counts

Every element anchored to a corner, so a resize cannot stack them on top of each
other. The HUD must never be the reason a screenshot looks broken.

## How to check your work

Render it and *look at it*:

```
./render.sh kerb downtown        # fixed camera presets
./run.sh --shot NAME             # chase camera
```

Then ask: is there a silhouette I can read? Is the road a mirror? Is there more
than one colour of light? Is the car visible? If the answer to any of those is
no, it is not done, regardless of what the numbers say.
