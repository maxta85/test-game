class_name AudioCues
extends RefCounted
## One-shot stings, synthesised on request and cached.
##
## AudioStreamWAV rather than a generator: a cue is a fraction of a second, so
## building it once costs nothing measurable and gives something that plays,
## stops, pitch-shifts and can be inspected like any other stream - which is
## how the check measures the envelope. Nothing is ever written to disk, so
## there is still no asset in the project.
##
## The whole bank is data. A cue is a frequency sweep, an envelope and one of
## three synthesis paths, so adding a sound is a line, not a function.

## Half the engine's rate: these are stings, not a bed, and nobody has ever
## noticed a one-shot at 22 kHz.
const MIX_HZ := 22050
## Every envelope is forced to exactly zero over this many seconds at the end.
## A cut-off sample is a click, and the last five milliseconds of a tail are
## inaudible - which makes this free.
const TAIL := 0.005

enum Kind {
	TONE,   ## A pitched sting: the countdown, the go, the UI.
	PULSE,  ## A windowed thump at f0. Impacts.
	NOISE,  ## Filtered noise with a tremolo. Tyres, clicks.
}

## The bank. dur/gain/attack/decay are seconds and a 0..1 level; f0 -> f1 is a
## linear sweep across the cue.
const RECIPES := {
	# The same pitch for all three lights on purpose: the ear counts beats, and
	# a rising pitch per light would sound like a game show.
	"count_3": {"kind": Kind.TONE, "dur": 0.40, "f0": 440.0, "f1": 440.0, "gain": 0.45, "attack": 0.004, "decay": 0.18},
	"count_2": {"kind": Kind.TONE, "dur": 0.40, "f0": 440.0, "f1": 440.0, "gain": 0.45, "attack": 0.004, "decay": 0.18},
	"count_1": {"kind": Kind.TONE, "dur": 0.40, "f0": 440.0, "f1": 440.0, "gain": 0.45, "attack": 0.004, "decay": 0.18},
	# GO rises, because a rising interval reads as go and a beep does not.
	"go": {"kind": Kind.TONE, "dur": 0.45, "f0": 520.0, "f1": 1040.0, "gain": 0.55, "attack": 0.004, "decay": 0.22},
	"shift": {"kind": Kind.NOISE, "dur": 0.08, "f0": 900.0, "f1": 1400.0, "gain": 0.35, "attack": 0.001, "decay": 0.02},
	"hit": {"kind": Kind.PULSE, "dur": 0.50, "f0": 74.0, "f1": 41.0, "gain": 0.85, "attack": 0.001, "decay": 0.10},
	"ui_ok": {"kind": Kind.TONE, "dur": 0.14, "f0": 880.0, "f1": 880.0, "gain": 0.30, "attack": 0.003, "decay": 0.05},
}

static var _cache: Dictionary = {}


static func has(name: String) -> bool:
	return RECIPES.has(name)


## Every cue in the bank, so a menu or the check can walk it without knowing
## the names.
static func names() -> Array:
	return RECIPES.keys()


static func seconds(name: String) -> float:
	return 0.0 if not RECIPES.has(name) else float(RECIPES[name]["dur"])


## The synthesised stream, or null for a name that is not in the bank. Null
## rather than a silent placeholder: a typo in a cue name should be visible in
## the return value, not audible as nothing happening.
static func stream(name: String) -> AudioStreamWAV:
	if _cache.has(name):
		return _cache[name]
	if not RECIPES.has(name):
		return null
	var built := _build(RECIPES[name])
	_cache[name] = built
	return built


static func _build(recipe: Dictionary) -> AudioStreamWAV:
	var dur := float(recipe["dur"])
	var gain := float(recipe["gain"])
	var attack := maxf(float(recipe["attack"]), 0.0001)
	var decay := maxf(float(recipe["decay"]), 0.005)
	var n := int(dur * float(MIX_HZ))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_HZ
	wav.stereo = false
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	var noise := 0.0
	var rng := 0x2545f491
	for i in n:
		var t := float(i) / float(MIX_HZ)
		var u := t / maxf(dur, 0.001)
		var hz := lerpf(float(recipe["f0"]), float(recipe["f1"]), u)
		phase += hz / float(MIX_HZ)
		if phase >= 1.0:
			phase -= 1.0
		var s := 0.0
		match int(recipe["kind"]):
			Kind.TONE:
				# Sine with some saw in it, so it cuts through engine noise
				# instead of being the quietest thing on the bus.
				s = sin(phase * TAU) * 0.75 + (phase * 2.0 - 1.0) * 0.25
			Kind.PULSE:
				# Windowed to nothing at both ends of the period. An exponential
				# pulse is still loud when the phase wraps, so it jumps back to
				# full at phase 0 - which is a click in the middle of a car
				# crash, and this project does not make clicks.
				s = pow(sin(PI * phase), 6.0)
			Kind.NOISE:
				rng = (rng * 1103515245 + 12345) & 0x7fffffff
				var white := float(rng) / 1073741824.0 - 1.0
				noise += (white - noise) * 0.4
				# The squeal is a tone under the noise, wobbling at a rate a
				# sliding tyre actually wobbles at.
				var tremolo := 1.0 - 0.45 * (1.0 - sin(TAU * 7.0 * t))
				s = noise * 0.6 + sin(phase * TAU) * 0.4 * tremolo
		var env := clampf(t / attack, 0.0, 1.0) * exp(-t / decay) * clampf((dur - t) / TAIL, 0.0, 1.0)
		var v := clampi(int(roundf(s * env * gain * 32767.0)), -32768, 32767)
		data[i * 2] = v & 0xff
		data[i * 2 + 1] = (v >> 8) & 0xff
	wav.data = data
	return wav
