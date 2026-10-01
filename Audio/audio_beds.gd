class_name AudioBeds
extends RefCounted
## The continuous layers of the soundtrack - the music bed, the night and the
## tyres - synthesised once and looped.
##
## Separate from `AudioCues` because a bed is not a sting. A cue is built to be
## played once, so it is enveloped down to silence at both ends - which is
## precisely what a loop must not do, since a bed that fades out every eight
## seconds pumps. So a bed is rendered one crossfade longer than it loops and the
## tail is folded back over the head: the buffer starts and ends on the same
## sample, so the seam is not something to be tolerated but something that is
## arithmetically absent.
##
## The brief asks for JDM classics drifting at night in Manunda. What is here is
## original arithmetic in that spirit - a minor-ninth pad with a pulse under it,
## a mains hum with two species of cricket over it - because reproducing a
## commercial recording is neither possible from arithmetic nor this project's
## idea of content. There is still not one sample file in the repository.
##
## ORIGINAL GAME CONTENT.

## Half the engine's rate, same as the cue bank: these are beds, not a mix, and a
## bed is a hiss before it is anything else.
const MIX_HZ := 22050
## Seconds of tail folded over the head. Long enough that the join is under the
## ear's ability to localise a discontinuity in a hiss, short enough that the
## eight second bed does not lose half a second of itself to it.
const XFADE := 0.08

enum Kind {
	MUSIC,  ## A minor-ninth pad over a pulse: the drive.
	NIGHT,  ## Mains hum, two species of cricket, a swell of distant traffic.
	TYRE,   ## A sliding contact patch: tone under noise, wobbling.
}

## The bank. `dur` is the length of the loop in seconds and `gain` its 0..1
## level; everything else a bed needs is a constant of its kind, because there
## are three of these and none of them is a family.
const RECIPES := {
	"music": {"kind": Kind.MUSIC, "dur": 8.0, "gain": 0.26},
	"night": {"kind": Kind.NIGHT, "dur": 8.0, "gain": 0.20},
	"tyre": {"kind": Kind.TYRE, "dur": 1.0, "gain": 0.55},
}

## --- the music bed: an A minor ninth, spread over three octaves
##
## Two oscillators per note, three and a half cents apart. That beat is what
## makes a chord sound like three instruments agreeing to play it rather than
## one synth playing three notes: unison detuning is the cheapest width there
## is.
const PAD_HZ := [55.0, 82.41, 110.0, 130.81, 164.81, 246.94]
const DETUNE := 1.0035
const PAD_PULSE_BPM := 72.0
## The filter breathes on an eight second cycle, so the pad is never quite the
## same brightness twice and an eight second loop does not read as eight
## seconds. Every rate in this file is a whole number of cycles per loop: a
## fractional one leaves the crossfade joining two different phases of itself,
## which is the seam the fold exists to remove.
const PAD_CUT_HZ := 520.0
const PAD_CUT_SWING := 900.0
const PAD_CUT_LFO_HZ := 0.125

## --- the night: 50 Hz mains, so 100 Hz and its harmonics
const HUM_HZ := [100.0, 200.0, 300.0]
const HUM_GAIN := 0.10
## Two species at their own rates, because crickets that pulse in unison sound
## like one cricket and a chorus is the whole point.
const CRICKET_HZ := [4260.0, 4520.0]
const CRICKET_GATE_HZ := [11.0, 7.25]
## A raised cosine rather than a square: an insect does not switch.
const CRICKET_DEPTH := 0.92
## Night air: the broadband bed the crickets sit on.
const AIR_TRACK := 0.055
## Distant traffic, swelling once per loop.
const SWELL_HZ := 0.125

## --- the tyre
##
## The tone under the noise is the contact patch; the wobble at 8.5 Hz is what
## a sliding tyre actually does to its own pitch, and it is why this is a loop
## that gets pitch-shifted by the caller rather than one long baked squeal.
const TYRE_HZ := 1180.0
const TYRE_WOBBLE_HZ := 9.0
const TYRE_WOBBLE_DEPTH := 0.12
const TYRE_NOISE_TRACK := 0.55
const TYRE_CUT_HZ := 3200.0

## A raised cosine between 0 and 1, `phase` in turns. Cheaper than a sine and a
## tenth of the code, and the shape that matters is the flat top and the soft
## knee, which this has.
static func _gate(phase: float) -> float:
	return 0.5 - 0.5 * cos(phase * TAU)

static var _cache: Dictionary = {}


## The synthesised, looped stream, or null for a name that is not in the bank.
static func stream(name: String) -> AudioStreamWAV:
	if _cache.has(name):
		return _cache[name]
	if not RECIPES.has(name):
		return null
	var wav := _build(RECIPES[name])
	_cache[name] = wav
	return wav


static func _build(recipe: Dictionary) -> AudioStreamWAV:
	var n := int(float(recipe["dur"]) * float(MIX_HZ))
	var x := mini(int(XFADE * float(MIX_HZ)), n)
	var gain := float(recipe["gain"])
	var out := _loop(_render(int(recipe["kind"]), n + x, gain), n, x)

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_HZ
	wav.stereo = false
	var data := PackedByteArray()
	data.resize(out.size() * 2)
	for i in out.size():
		var v := clampi(int(roundf(out[i] * 32767.0)), -32768, 32767)
		data[i * 2] = v & 0xff
		data[i * 2 + 1] = (v >> 8) & 0xff
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = out.size()
	return wav


## Folds the crossfade back over the head so the last sample flows into the
## first. Equal power would be the textbook choice and is wrong here: the two
## halves are the same signal a moment apart, so summing them dry keeps the
## level through the seam and the whole loop at one volume.
static func _loop(samples: PackedFloat32Array, n: int, x: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = samples[i] if i >= x else samples[i] * (float(i) / float(x)) + samples[n + i] * (1.0 - float(i) / float(x))
	return out


# ------------------------------------------------------------------- synthesis

static func _render(kind: int, n: int, gain: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	match kind:
		Kind.MUSIC:
			_render_music(out, gain)
		Kind.NIGHT:
			_render_night(out, gain)
		Kind.TYRE:
			_render_tyre(out, gain)
	return out


## A held chord with a pulse under it. Every parameter moves through a one-pole,
## because the cutoff LFO alone is enough of a step to click without one.
static func _render_music(out: PackedFloat32Array, gain: float) -> void:
	var rate := float(MIX_HZ)
	var n := out.size()
	var pulse_hz := PAD_PULSE_BPM / 60.0
	var pa := PackedFloat32Array()
	var pb := PackedFloat32Array()
	pa.resize(PAD_HZ.size())
	pb.resize(PAD_HZ.size())
	var lp := 0.0
	var cut := PAD_CUT_HZ
	for i in n:
		var t := float(i) / rate
		cut += (PAD_CUT_HZ + PAD_CUT_SWING * (0.5 + 0.5 * sin(TAU * PAD_CUT_LFO_HZ * t)) - cut) * 0.0004
		var s := 0.0
		for k in PAD_HZ.size():
			var f := float(PAD_HZ[k])
			pa[k] = fposmod(pa[k] + f * DETUNE / rate, 1.0)
			pb[k] = fposmod(pb[k] + f / (DETUNE * rate), 1.0)
			s += (sin(pa[k] * TAU) * 0.72 + (pa[k] * 2.0 - 1.0) * 0.28
				+ sin(pb[k] * TAU) * 0.72 + (pb[k] * 2.0 - 1.0) * 0.28) * 0.5
		s /= float(PAD_HZ.size())
		# The pulse: a decaying sine on every eighth note, so the bed has a pulse
		# rate the ear can lock to without it being a drum track.
		var beat := fposmod(t * pulse_hz, 1.0)
		s += sin(TAU * float(PAD_HZ[0]) * t) * exp(-beat * 7.0) * 0.34
		lp += (s - lp) * (1.0 - exp(-TAU * cut / rate))
		out[i] = lp * gain


## Mains hum under two species of cricket over a swell of traffic.
static func _render_night(out: PackedFloat32Array, gain: float) -> void:
	var rate := float(MIX_HZ)
	var n := out.size()
	var lp := 0.0
	var air := 0.0
	var rng := 0x2545f491
	for i in n:
		var t := float(i) / rate
		var s := 0.0
		for k in HUM_HZ.size():
			s += sin(TAU * float(HUM_HZ[k]) * t) / float(k + 2)
		s *= HUM_GAIN
		for k in CRICKET_HZ.size():
			var ph := fposmod(t * float(CRICKET_GATE_HZ[k]), 1.0)
			s += sin(TAU * float(CRICKET_HZ[k]) * t) * _gate(ph) * CRICKET_DEPTH / float(k + 1)
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white := float(rng) / 1073741824.0 - 1.0
		air += (white - air) * 0.08
		var swell := 0.5 + 0.5 * sin(TAU * SWELL_HZ * t - PI * 0.5)
		s += air * AIR_TRACK * (0.5 + swell)
		lp += (s - lp) * (1.0 - exp(-TAU * 5200.0 / rate))
		out[i] = lp * gain


## A contact patch sliding. The player's pitch_scale and volume do the rest.
static func _render_tyre(out: PackedFloat32Array, gain: float) -> void:
	var rate := float(MIX_HZ)
	var n := out.size()
	var ph := 0.0
	var noise := 0.0
	var lp := 0.0
	var rng := 0x1a2b3c4d
	for i in n:
		var t := float(i) / rate
		var wobble := 1.0 + TYRE_WOBBLE_DEPTH * sin(TAU * TYRE_WOBBLE_HZ * t)
		ph = fposmod(ph + TYRE_HZ * wobble / rate, 1.0)
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white := float(rng) / 1073741824.0 - 1.0
		noise += (white - noise) * TYRE_NOISE_TRACK
		var s := sin(ph * TAU) * 0.62 + noise * 0.38
		lp += (s - lp) * (1.0 - exp(-TAU * TYRE_CUT_HZ / rate))
		out[i] = lp * gain
