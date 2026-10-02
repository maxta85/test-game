class_name EngineSynth
extends RefCounted
## An engine, as arithmetic: no sample, no file, no audio device.
##
## The DSP lives in a RefCounted rather than inside the player, because that is
## what makes it testable. `./test.sh` runs with `--audio-driver Dummy`, where
## the generator is never drained and no frames ever come back, so a player-side
## synth could only ever be checked for "did not crash". Rendered into a plain
## array it can be measured: is it loud enough, does the pitch move with rpm, is
## there a click at the seam.
##
## Three things make it read as an engine rather than as a siren:
##  - it fires on cylinders/2 pulses per revolution, not once per revolution, so
##    the fundamental sits where a real four-stroke's does (an idling six is
##    ~40 Hz, not 13);
##  - load opens it: more upper harmonics, more intake noise, a brighter filter
##    and more level, which is the difference between a car being towed and a car
##    being driven;
##  - every parameter the game can change moves through a one-pole smoother.
##    A step in a resonant signal is a click, not a note, and rpm arrives at 60 Hz
##    with all the noise a physics step puts on it.
##
## Deterministic: the noise comes from a fixed-seed LCG, so the same inputs give
## the same samples and a check can compare two renders exactly.

const MIX_RATE := 44100.0
## A four-stroke fires cylinders/2 times per revolution.
const DEFAULT_CYLINDERS := 6
## Below idle the engine is not turning over but is still turning; the floor
## keeps a zero rpm from becoming a zero frequency, which is a DC step.
const IDLE_RPM := 800.0
const REDLINE := 9000.0

## Seconds for rpm, load and the run/stop fade to close 63% of the gap.
const RPM_TAU := 0.08
const LOAD_TAU := 0.12
const FADE_TAU := 0.06
## Idle is soft and round, full load is a hard blat.
const PULSE_IDLE := 3.0
const PULSE_LOAD := 9.0
## Intake noise is a one-pole above white; white on its own is a hiss.
const NOISE_TRACK := 0.35
## Filter corner, idle -> full load.
const CUT_IDLE := 320.0
const CUT_LOAD := 5200.0
## One-pole high-pass, ~21 Hz at 44.1 kHz. The firing pulse train is mostly DC
## and a raw DC offset on a bus thumps harder than the engine.
const DC_R := 0.997

## Nothing turns over until something starts it. A synthesiser that defaults to
## running is an engine that idles in the main menu, with no car anywhere in
## the world to be idling: measured on the Engine bus at -32 dB with zero
## CarBody nodes in the tree. `EngineVoice` does not even play until it is told
## to, so this is belt and braces - but the state this defaults to is the state
## a car-less world has to be in, and it belongs here rather than being set once
## by a caller that may never arrive.
var mix_rate: float = MIX_RATE
var cylinders: int = DEFAULT_CYLINDERS
var running: bool = false

var _target_rpm: float = IDLE_RPM
var _target_load: float = 0.0
var _rpm: float = IDLE_RPM
var _load: float = 0.0
var _fade: float = 0.0
var _phase: float = 0.0
var _noise: float = 0.0
var _lp: float = 0.0
var _dc_prev: float = 0.0
var _dc_out: float = 0.0
var _level: float = 0.0
## Fixed seed: the noise is a fixture, not a flake.
var _rng: int = 0x1a2b3c4d


## Pulses per second at `rpm`. Public because it is the one number that says
## whether this sounds like an engine: guarded, not merely clamped at the top,
## because a caller computing rpm from speed and wheel circumference hands us a
## zero on the first frame of a race and a zero fundamental is a click.
static func firing_frequency(rpm: float, cyl: int = DEFAULT_CYLINDERS) -> float:
	var r := rpm
	if not is_finite(r) or r < IDLE_RPM * 0.5:
		r = IDLE_RPM * 0.5
	return clampf(r / 60.0 * maxf(float(cyl), 1.0) * 0.5, 8.0, 20000.0)


## The target state. Called every frame with whatever the car happens to have,
## so it sanitises rather than trusts: non-finite becomes idle, load is a 0..1
## fraction, rpm is clamped to something a piston could have made.
func set_engine(rpm: float, load: float) -> void:
	_target_rpm = clampf(rpm, IDLE_RPM * 0.5, REDLINE * 1.2) if is_finite(rpm) else IDLE_RPM
	_target_load = clampf(load, 0.0, 1.0) if is_finite(load) else 0.0


## Fades the engine in or out instead of cutting it, so starting and stopping a
## car does not click. How long it is left rendering after `false` is
## `EngineVoice`'s decision and not this class's: the fade is a ramp on samples,
## and samples only exist while somebody is rendering them, so this can only
## close as fast as a ring the audio server is draining lets it. The voice stops
## the player itself once the ramp has landed, and that - not this flag - is
## what makes the Engine bus actually empty.
func set_running(on: bool) -> void:
	running = on


## Current firing frequency, after smoothing - what is actually sounding.
func frequency() -> float:
	return firing_frequency(_rpm, cylinders)


## RMS of the most recent render, so a caller can meter the engine without
## keeping the samples.
func level() -> float:
	return _level


## Smoothed load, 0..1.
func load() -> float:
	return _load


func reset() -> void:
	_target_rpm = IDLE_RPM
	_target_load = 0.0
	_rpm = IDLE_RPM
	_load = 0.0
	_fade = 1.0 if running else 0.0
	_phase = 0.0
	_noise = 0.0
	_lp = 0.0
	_dc_prev = 0.0
	_dc_out = 0.0
	_level = 0.0
	_rng = 0x1a2b3c4d


## Fills `out` with `out.size()` mono samples and leaves it untouched if empty.
## Smoothing advances per sample, not per call, so a caller's frame time is the
## only thing that decides how long a change takes.
func render(out: PackedFloat32Array) -> void:
	var n := out.size()
	if n <= 0:
		return
	var rate := maxf(mix_rate, 1000.0)
	var k_rpm := 1.0 - exp(-1.0 / (RPM_TAU * rate))
	var k_load := 1.0 - exp(-1.0 / (LOAD_TAU * rate))
	var k_fade := 1.0 - exp(-1.0 / (FADE_TAU * rate))
	var want := 1.0 if running else 0.0
	var sum_sq := 0.0
	for i in n:
		_rpm += (_target_rpm - _rpm) * k_rpm
		_load += (_target_load - _load) * k_load
		_fade += (want - _fade) * k_fade

		# Wrap rather than fmod: the phase stays in 0..1 forever, so the sound
		# does not drift in pitch after the first few minutes of a long run.
		_phase += firing_frequency(_rpm, cylinders) / rate
		if _phase >= 1.0:
			_phase -= 1.0

		var sharp := lerpf(PULSE_IDLE, PULSE_LOAD, _load)
		var body := exp(-sharp * _phase) * 0.8
		# The saw is the gearbox and the timing chain: thin at idle, forward of
		# the engine on load.
		body += (_phase * 2.0 - 1.0) * lerpf(0.12, 0.40, _load)
		_noise += (_next_noise() - _noise) * NOISE_TRACK
		body += _noise * lerpf(0.06, 0.46, _load)

		_lp += (body - _lp) * (1.0 - exp(-TAU * lerpf(CUT_IDLE, CUT_LOAD, _load) / rate))
		_dc_out = _lp - _dc_prev + DC_R * _dc_out
		_dc_prev = _lp

		var s := clampf(_dc_out * _fade * lerpf(0.30, 0.80, _load), -1.0, 1.0)
		out[i] = s
		sum_sq += s * s
	_level = sqrt(sum_sq / float(n))


func _next_noise() -> float:
	_rng = (_rng * 1103515245 + 12345) & 0x7fffffff
	return float(_rng) / 1073741824.0 - 1.0
