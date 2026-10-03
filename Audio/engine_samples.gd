class_name EngineSamples
extends RefCounted
## The recorded engine: which sample plays at which revs, and how loud.
##
## Everything here is a decision with a source. Nothing in this file is a taste
## call dressed up as a number - each constant names the file, the line or the
## measurement it came from, so a change to any of them can be argued with.
##
## The samples are four pitches of one recording (see `assets/audio/LICENSE`:
## "Difference between the files is pitch only"). So this table is not a set of
## different engines to switch between - it is one engine in four gears of
## pitch, and `pitch_scale` is what actually carries the revs. The bands exist so
## that the pitch correction a layer has to apply stays inside a sane range and so
## that adding a genuinely different recording later has somewhere to go.
##
## `EngineSynth` is the fallback, not the alternative: with no samples present
## `have_samples()` is false and the voice synthesises exactly as it always did.
##
## ORIGINAL GAME CODE. The sample files are CC0; see assets/audio/LICENSE.

## The loops, idle first. Renamed by role rather than by source name because the
## source called them `loop_0`, `loop_1_0`, `loop_3_0`, `loop_5_0`, which says
## nothing about revs. Measured fundamentals are in `LAYER_HZ` below.
const LAYERS: Array[String] = [
	"res://assets/audio/engine/idle.wav",
	"res://assets/audio/engine/cruise.wav",
	"res://assets/audio/engine/pull.wav",
	"res://assets/audio/engine/redline.wav",
]

## Measured fundamental of each file above, in Hz, by autocorrelation over the
## middle third searched 40..400 Hz. Measured from these exact files on
## 2026-10-02; the table is reproduced in assets/audio/LICENSE and asserted
## against the samples by Tests/test_t67_engine_samples.gd, so a swapped file
## cannot quietly leave the pitch maths describing a recording that is gone.
const LAYER_HZ: Array[float] = [43.1, 60.3, 70.8, 76.7]

## Band edges as a fraction of the car's own redline, so one table covers a
## 6800 rpm naturally-aspirated four and an 8200 rpm turbo six:
##
##  0.32 - `shift_down_rpm` over `redline`. The roster's `shift_down_rpm` is
##         2200..3100 and the roster's `redline` is 6800..8200
##         (Vehicles/car_db.gd); the lowest ratio in that set is 2200/6800 =
##         0.3235. Below this the engine is either below idle or falling into a
##         downshift, and either way it is not being asked for more than it has.
##  0.50 - the top of the turbo spool band over the lowest redline.
##         `turbo_threshold_rpm` is 2800..3400 in the roster; 3400/6800 = 0.5.
##         Above this every turbo in the game is spooling.
##  0.75 - where the turbo's own spool is finished. Systems/vehicle/car_body.gd
##         computes `headroom = (engine_rpm - turbo_threshold_rpm) / 2500`, and
##         that saturates at threshold + 2500 = 5300..5900 rpm, which is
##         0.78..0.72 of redline. 0.75 sits inside that bracket.
##  1.00 - redline, where car_body.gd starts cutting torque over the last 250 rpm.
const BAND_EDGES: Array[float] = [0.0, 0.32, 0.50, 0.75, 1.0]

## How much of a band is spent crossfading into the next layer.
##
## Systems/vehicle/car_body.gd moves rpm with `move_toward(engine_rpm, target_rpm,
## delta * 6000.0)` under power - 6000 rpm/s is the fastest the engine can climb.
## The widest band is 0.50..0.75, which on tatsuya_gt (redline 8000) is 2000 rpm,
## and 0.12 of that is 240 rpm: 0.04 s at 6000 rpm/s. Short enough that the
## hand-over is a blend rather than a pitch step, long enough that it happens
## over several 60 Hz physics frames instead of inside one.
const XFADE := 0.12

## The samples as they sit in the tree are loud: measured rms 0.395, which is
## -8.1 dBFS. EngineSynth, rendering the same engine, measures -28.6 dBFS at idle
## and -16.5 dBFS at full load (1.0 s renders at 44.1 kHz, 4 and 6 cylinders,
## 850..7400 rpm; table in the t67 report). TRIM_DB lands the sample path on the
## synth's own idle figure so that swapping between them does not jump the mix.
const TRIM_DB := -21.0

## How far the engine opens between off-throttle and full load, in dB, on top of
## TRIM_DB. 12.5 dB is the span EngineSynth actually measures (-28.6 -> -16.5),
## not the 8.5 dB its own `lerpf(0.30, 0.80, load)` gain law spans: the synth's
## extra growth comes from the pulse train sharpening (`PULSE_IDLE` 3 ->
## `PULSE_LOAD` 9) and the filter opening (320 Hz -> 5200 Hz), neither of which a
## recorded loop does on its own. Taking the measured span instead means the
## sample path opens by the same amount the fallback did, so Tests/test_sound.gd's
## "and on full throttle it is louder" still has the same margin behind it.
const LOAD_SPAN_DB := 12.5

## `AudioStreamPlayer.pitch_scale` is documented 0.01..4.0 with 1.0 the original
## rate, so 4.0 is the engine's own ceiling and not a choice. The floor of 0.5 is
## this pack's: the lowest thing the voice ever asks for is a four-cylinder at
## idle, 800 rpm * 4 / 2 / 60 = 26.7 Hz against `idle.wav`'s 43.1 Hz, which is
## 0.62 - so 0.5 has headroom.
##
## 4.0 is aliasing-free for these files, which is the reason one recording can
## cover the rev range at all: 99% of their energy is below 689 Hz, so at 4x all
## of it is below 2.8 kHz and nothing folds back.
##
## Both ends of the range are reached, deliberately, and
## `Tests/test_t67_engine_samples.gd` says exactly where so it cannot drift:
##
##   - The ceiling is reached above 6136 rpm on a six-cylinder - the top 23% of a
##     8000 rpm tatsuya_gt, where the firing order needs 400 Hz and redline.wav
##     tops out at 306.8. Past that the six stops climbing in pitch, which is the
##     one thing this bank cannot do and is why the flare is load-driven and not
##     pitch-driven. A four tops out needing 276.7 Hz at redline (scale 3.61) and
##     never reaches it.
##   - The floor is reached below 648 rpm on a four, which `car_body.gd` allows:
##     it clamps to `idle_rpm * 0.5` = 400 rpm on a stalled four, and 400 rpm
##     needs 13.3 Hz = scale 0.31. The engine buries in pitch going stalled and
##     climbs out of it, which is what a stalled four sounds like.
const PITCH_MIN := 0.5
const PITCH_MAX := 4.0

## The wastegate voice. A short air release played when a spooling turbo is
## let go of; see `EngineVoice.set_boost`.
const BLOWOFF := "res://assets/audio/turbo/blowoff.ogg"

## Used when no car has said what its redline is. tatsuya_gt's 8000 rpm - a real
## number from Vehicles/car_db.gd, and mid-range for the roster.
const DEFAULT_REDLINE := 8000.0

## The six-cylinder's standing: `firing_frequency` already exists on EngineSynth
## and is the only definition of "how fast is this engine firing" in the project.
## Wrapped so a caller holding samples does not have to know that.
static func target_hz(rpm: float, cyl: int) -> float:
	return EngineSynth.firing_frequency(rpm, cyl)


## The streams, loaded once. Empty if any layer is missing, which is what puts
## the voice on its synthesiser.
static var _streams: Array[AudioStream] = []
static var _loaded := false


static func streams() -> Array[AudioStream]:
	if not _loaded:
		_loaded = true
		_streams = []
		for path in LAYERS:
			var s := load(path) as AudioStream
			if s == null:
				_streams = []
				return _streams
			_streams.append(s)
	return _streams


static func have_samples() -> bool:
	return streams().size() == LAYERS.size()


static func blowoff_stream() -> AudioStream:
	return load(BLOWOFF) as AudioStream


## Which band a revs fraction falls in. `f` is clamped first, because rpm arrives
## from a physics step and can be a zero on the first frame of a race.
static func band_for(f: float) -> int:
	var v := clampf(f, 0.0, 1.0)
	for i in range(BAND_EDGES.size() - 2, -1, -1):
		if v >= BAND_EDGES[i]:
			return i
	return 0


## The two layers to have playing and how far between them the revs are, as
## `{a: int, b: int, mix: float}` with `mix` 0..1 from `a` to `b`. `a == b` and
## `mix == 0` means one layer alone.
##
## Linear, not equal-power: the four layers are four pitches of one recording, so
## they are near-identical waveforms and an equal-power blend would put a 3 dB
## hump at the middle of every hand-over. Linear holds the level flat.
static func layers_for(f: float) -> Dictionary:
	var v := clampf(f, 0.0, 1.0)
	var band := band_for(v)
	var last := LAYERS.size() - 1
	if band >= last:
		return {"a": last, "b": last, "mix": 0.0}
	var lo := BAND_EDGES[band]
	var hi := BAND_EDGES[band + 1]
	var local := clampf((v - lo) / maxf(hi - lo, 1e-6), 0.0, 1.0)
	if local < 1.0 - XFADE:
		return {"a": band, "b": band, "mix": 0.0}
	return {"a": band, "b": band + 1, "mix": clampf((local - (1.0 - XFADE)) / XFADE, 0.0, 1.0)}


## How fast a layer has to be played for the engine to be firing at `hz`.
static func pitch_scale(layer: int, hz: float) -> float:
	if layer < 0 or layer >= LAYER_HZ.size():
		return 1.0
	if not is_finite(hz) or hz <= 0.0:
		return 1.0
	return clampf(hz / LAYER_HZ[layer], PITCH_MIN, PITCH_MAX)


## This layer's volume, in dB, for a given load. `load` is 0..1.
static func level_db(load: float) -> float:
	return TRIM_DB + clampf(load, 0.0, 1.0) * LOAD_SPAN_DB
