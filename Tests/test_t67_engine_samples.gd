extends RefCounted
## The recorded engine bank: which sample the revs pick, what it is played at,
## and that it is actually a recorded, licensed sample rather than the
## synthesiser wearing a sample's name.
##
## The failure this exists to catch is a sound bank that is a fiction - a table
## of numbers with nothing behind it. `EngineSamples` would happily report
## `have_samples() == true` for a pack of imports that failed, a licence that
## does not cover the files, or a loop whose seam clicks once a second, and every
## check that only read the table would still pass. So the checks come in two
## directions: the table is pinned against the roster's real redlines and
## cylinder counts, and the files behind it are opened and measured rather than
## believed.
##
## ORIGINAL GAME CONTENT.

## Every file in the bank, against `assets/audio/LICENSE`, which has to name each
## one. Attribution is not a formality: these are recordings by other people.
const BANK := [
	"res://assets/audio/engine/idle.wav",
	"res://assets/audio/engine/cruise.wav",
	"res://assets/audio/engine/pull.wav",
	"res://assets/audio/engine/redline.wav",
	"res://assets/audio/turbo/blowoff.ogg",
]
const LICENSE := "res://assets/audio/LICENSE"

## A bus at or below this is silence; a player parked at the -80 dB trim reads
## about -87. The same threshold Tests/test_sound.gd uses, for the same reason.
const SILENT := -70.0

var _tree: SceneTree


func run(t: TestHarness) -> void:
	t.suite("t67_engine_samples")
	_tree = t.tree
	await _ticks(2)
	_files_are_real(t)
	_licence_covers_them(t)
	_the_layers_loop(t)
	await _the_voice_plays_them(t)
	_table_follows_the_revs(t)
	_clamps_are_where_we_say(t)
	await _the_fallback_is_still_there(t)
	await _the_wastegate_fires_on_a_lift(t)


# ------------------------------------------------------------- the files

## What is on disk, opened rather than assumed. A missing or empty file is the
## one failure every table-driven check would sail past.
func _files_are_real(t: TestHarness) -> void:
	for path in BANK:
		var f := FileAccess.open(path, FileAccess.READ)
		if not t.ok(f != null, "the bank has %s" % path.get_file()):
			continue
		t.gt(f.get_length(), 1024.0, "%s is not an empty placeholder  (%d bytes)"
				% [path.get_file(), f.get_length()])
	t.ok(EngineSamples.have_samples(),
			"the voice will use the samples rather than the fallback")
	t.eq(EngineSamples.streams().size(), 4,
			"four layers, one per band  (%d)" % EngineSamples.streams().size())
	t.eq(EngineSamples.BLOWOFF, "res://assets/audio/turbo/blowoff.ogg",
			"and the wastegate is the file, not a synthesised hiss")


## Attribution. The licence is read, and every file in the bank has to be named
## in it, so a sample added without a credit cannot pass by merely existing.
func _licence_covers_them(t: TestHarness) -> void:
	var f := FileAccess.open(LICENSE, FileAccess.READ)
	if not t.ok(f != null, "assets/audio/LICENSE is in the repo"):
		return
	var text := f.get_as_text()
	t.gt(float(text.length()), 400.0, "and it says something  (%d bytes)" % text.length())
	for path in BANK:
		t.gt(float(text.find(path.get_file())), -1.0,
				"the licence names %s" % path.get_file())
	# CC0 is the only licence this project ships recorded third-party audio
	# under, so it has to be written down rather than implied by a filename.
	t.gt(float(text.to_lower().find("cc0")), -1.0, "and says the licence is CC0")
	t.gt(float(text.to_lower().find("opengameart")), -1.0,
			"and where the recordings came from")


## A loop that does not loop is a click every 0.6 s, and at -21 dB a click is
## not subtle. `loop_mode` is read off the imported resource, so this fails if
## the import preset drifts as well as if the code does.
func _the_layers_loop(t: TestHarness) -> void:
	var streams := EngineSamples.streams()
	for i in streams.size():
		var s := streams[i] as AudioStreamWAV
		if not t.ok(s != null, "layer %d imported as a wav" % i):
			continue
		t.eq(s.loop_mode, AudioStreamWAV.LOOP_FORWARD, "layer %d loops forward" % i)
		t.between(s.get_length(), 0.4, 2.0,
				"layer %d is long enough to hide a seam  (%.3f s)" % [i, s.get_length()])
	# The blowoff is a one-shot: it must not drone for the rest of the race.
	var bo := EngineSamples.blowoff_stream() as AudioStreamOggVorbis
	if t.ok(bo != null, "the wastegate sample imported"):
		t.eq(bo.loop, false, "and is a one-shot, not a loop")
		t.between(bo.get_length(), 0.1, 0.6,
				"and is about as long as a blowoff  (%.3f s)" % bo.get_length())


## The end-to-end path: a voice in a tree, told where the revs are, comes out
## playing one of the four layers pitched to the firing frequency. `sounding_hz`
## is read back off the players themselves, not off the table that asked.
func _the_voice_plays_them(t: TestHarness) -> void:
	var voice := _voice()
	if not t.ok(voice != null, "an engine voice to drive"):
		return
	voice.set_redline(EngineSamples.DEFAULT_REDLINE)
	voice.synth.cylinders = 4
	voice.synth.set_engine(800.0, 0.0)
	voice.set_sounding(true)
	await _ticks(20)

	t.ok(voice.sample_mode(), "which is on the samples")
	t.ok(voice.queued_frames() > 0, "with frames queued, not a silent player")
	t.ok(voice.sounding(), "and sounding")
	t.gt(voice.synth.fade(), 0.9, "with the fade open  (%.3f)" % voice.synth.fade())

	for step in [[2000.0, 0.0], [4800.0, 0.5], [7400.0, 1.0]]:
		var rpm := float(step[0])
		voice.synth.set_engine(rpm, float(step[1]))
		# The synth slews its own rpm, at the rate `car_body.gd` turns the
		# crank, so the voice is still crossing bands a frame after the revs are
		# asked for. Reading the layers mid-slew measures the hand-over, which is
		# what the next section is for, not what this one is checking.
		await _settle(voice, rpm)
		t.ok(voice.sample_mode(), "%d rpm is still the samples" % int(rpm))
		var hz: Array = voice.layer_state()["sounding_hz"]
		var heard := 0
		var loudest := 0.0
		for h in hz:
			if float(h) > 0.0:
				heard += 1
				loudest = float(h)
		t.eq(heard, 1, "%d rpm sounds exactly one layer  (%d)" % [int(rpm), heard])
		# The layer's base times its pitch scale has to equal the firing order's
		# frequency - that is the whole claim of the table, read back off the
		# player rather than off `EngineSamples`.
		t.near(loudest, EngineSamples.target_hz(voice.sounding_rpm(), 4), 0.5,
				"%d rpm is played at the firing frequency  (%.1f Hz)"
				% [int(rpm), loudest])

	# Loudness has to follow the throttle, or the car sounds the same at idle and
	# at the limiter and the whole rev range is one flat noise.
	t.near(EngineSamples.level_db(1.0) - EngineSamples.level_db(0.0),
			EngineSamples.LOAD_SPAN_DB, 0.01,
			"the load span is the %.1f dB it claims" % EngineSamples.LOAD_SPAN_DB)
	voice.synth.set_engine(800.0, 0.0)
	await _settle(voice, 800.0)
	var idle: Array = voice.layer_state()["volumes"]
	voice.synth.set_engine(7600.0, 1.0)
	await _settle(voice, 7600.0)
	var loud: Array = voice.layer_state()["volumes"]
	t.gt(_peak_layer(loud), _peak_layer(idle) + 1.0,
			"the top layer is audibly above the idle one  (%.1f dB vs %.1f dB)"
			% [_peak_layer(loud), _peak_layer(idle)])
	for v in idle:
		t.between(float(v), -80.0, 6.0, "and every layer parks inside the mix")

	voice.set_sounding(false)
	await _ticks(4)
	t.fails(voice.sounding(), "and it stops when the car goes")


## The table against the roster. Every band's edges and crossfades, and the pitch
## each car actually ends up at - so a `Vehicles/car_db.gd` change that pushed a
## car out of the bank's range fails here rather than in somebody's ear.
func _table_follows_the_revs(t: TestHarness) -> void:
	t.eq(EngineSamples.LAYER_HZ.size(), 4, "a measured base frequency per layer")
	for h in EngineSamples.LAYER_HZ:
		t.between(float(h), 30.0, 200.0,
				"a layer base is in singing range  (%.1f Hz)" % float(h))

	# Bands, at their edges and a quarter of the way into the next one.
	var edges := EngineSamples.BAND_EDGES
	t.eq(edges.size(), 5, "four bands over five edges")
	for i in range(1, edges.size() - 1):
		var edge := float(edges[i])
		var m := EngineSamples.layers_for(edge)
		t.eq(int(m["b"]), i, "%.2f of the range starts layer %d" % [edge, i])
		t.between(float(m["mix"]), 0.0, 0.05,
				"%.2f of the range is not yet crossfaded  (mix %.2f)"
				% [edge, float(m["mix"])])
		# The crossfade is the last XFADE of the band, not the whole of it: the
		# old layer holds all the way through and hands over over the final 12%.
		var band := float(edges[i + 1]) - edge
		for where in [0.25, 0.5, 0.75]:
			var at := EngineSamples.layers_for(edge + band * where)
			t.eq(float(at["mix"]), 0.0,
					"%.0f%% into band %d is still all layer %d  (mix %.2f)"
					% [where * 100.0, i, i, float(at["mix"])])
		# The top band is the top of the range, so nothing hands over out of it -
		# `layers_for` returns the one layer outright.
		var last_band := i >= EngineSamples.LAYERS.size() - 1
		if last_band:
			continue
		var start := edge + band * (1.0 - EngineSamples.XFADE)
		var mid := EngineSamples.layers_for(start + band * EngineSamples.XFADE * 0.5)
		t.near(float(mid["mix"]), 0.5, 0.02,
				"and halfway through the fade at the top of band %d is halfway  (%.2f)"
				% [i, float(mid["mix"])])
		# Continuity across the hand-over: as the band ends, the incoming layer has
		# to be all the way up. It reaches 1.0 exactly *at* the edge, which already
		# belongs to the next band, so this asks for all but the last sliver.
		var done := EngineSamples.layers_for(edge + band - 0.0005)
		t.gt(float(done["mix"]), 0.9,
				"and band %d hands all the way over  (%.3f)" % [i, float(done["mix"])])
		t.eq(int(done["b"]), i + 1, "to the next layer")

	# The pitch a car ends up at, from the real roster: the firing frequency over
	# the layer's own measured base.
	for id in CarDB.ALL_IDS:
		var spec := CarDB.get_spec(id)
		var cyl := _cylinders(id)
		var redline := float(spec.redline)
		t.gt(redline, 0.0, "%s has a redline to cover" % id)
		for frac in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var rpm := redline * float(frac)
			var m := EngineSamples.layers_for(float(frac))
			var want := EngineSamples.target_hz(rpm, cyl)
			for layer in [int(m["a"]), int(m["b"])]:
				var base := EngineSamples.LAYER_HZ[int(layer)]
				var scale := EngineSamples.pitch_scale(int(layer), want)
				# What the layer is played at is the firing frequency pulled inside
				# the range that one sample can reach - equal to it unless the
				# clamp bit, which is what the clamp section pins.
				var lo := base * EngineSamples.PITCH_MIN
				var hi := base * EngineSamples.PITCH_MAX
				var reached := clampf(want, lo, hi)
				t.near(scale * base, reached, 0.05,
						"%s at %d%% of redline plays layer %d at %.1f Hz  (wants %.1f)"
						% [id, int(float(frac) * 100.0), int(layer),
								scale * base, want])
				t.between(scale, EngineSamples.PITCH_MIN, EngineSamples.PITCH_MAX,
						"%s %d%% of redline is inside the pitch range  (%.2f)"
						% [id, int(float(frac) * 100.0), scale])


## Both ends of the pitch range are reached on purpose, and `EngineSamples` says
## where. This walks the roster and pins both, in rpm, against what the docs
## claim - so a taller car or a moved redline cannot change the answer quietly.
func _clamps_are_where_we_say(t: TestHarness) -> void:
	# The ceiling. Layer 3 tops out at LAYER_HZ[3] * PITCH_MAX, so a six runs out
	# of sample once its firing order asks for more than that.
	var top := EngineSamples.LAYER_HZ[3] * EngineSamples.PITCH_MAX
	t.near(top, 306.8, 0.05, "the top layer can reach %.1f Hz" % top)
	t.near(EngineSamples.target_hz(top * 20.0, 6), top, 0.05,
			"which a six-cylinder reaches at %.0f rpm" % (top * 20.0))
	t.eq(EngineSamples.pitch_scale(3, EngineSamples.target_hz(8000.0, 6)),
			EngineSamples.PITCH_MAX, "so a 8000 rpm six sits on the ceiling")
	# A four does not: 6800 rpm wants 226.7 Hz, 3.61x the top layer's own base.
	t.near(EngineSamples.pitch_scale(3, EngineSamples.target_hz(6800.0, 4)),
			226.7 / 76.7, 0.005, "a 6800 rpm four stays under it  (%.2fx)"
			% EngineSamples.pitch_scale(3, EngineSamples.target_hz(6800.0, 4)))

	# And every car in the roster, counted rather than assumed.
	var ceiling := 0
	var total := 0
	for id in CarDB.ALL_IDS:
		var spec := CarDB.get_spec(id)
		total += 1
		if EngineSamples.pitch_scale(3, EngineSamples.target_hz(float(spec.redline),
				_cylinders(id))) >= EngineSamples.PITCH_MAX - 0.001:
			ceiling += 1
		var idle := EngineSamples.pitch_scale(0, EngineSamples.target_hz(
				float(spec.idle_rpm), _cylinders(id)))
		t.between(idle, EngineSamples.PITCH_MIN, EngineSamples.PITCH_MAX,
				"%s idles inside the pitch range  (%.2f)" % [id, idle])
	t.ok(ceiling > 0, "at least one car reaches the ceiling  (%d)" % ceiling)
	t.ok(ceiling < total, "and not every one does  (%d of %d)" % [ceiling, total])


## The bank is an upgrade, not a replacement: with the files gone the voice falls
## back to the synthesiser and still makes an engine. The synthesiser's own
## smoother is also what the sample path rides for its fade, so if it did not
## close, the recorded engine could neither open nor shut.
func _the_fallback_is_still_there(t: TestHarness) -> void:
	# Read off the voice's own synth, which is in a tree and being rendered.
	# A detached `EngineSynth.new()` is silent by design - nothing calls `render`
	# on it - so asking one for `level()` measures nothing, which is the same
	# mistake `Audio/audio_check.gd` documents and avoids.
	var voice := _voice()
	if not t.ok(voice != null, "a voice with a synth in it"):
		return
	# It has to be sounding: `EngineVoice._process` switches itself off when the
	# engine stops, and with nothing rendering the fade freezes wherever it was and
	# the rpm stops arriving. That is the fallback behaving correctly and reading
	# it as "the getters do not work" would be measuring the wrong thing.
	voice.set_sounding(true)
	await _ticks(20)
	var synth := voice.synth
	synth.set_engine(EngineSynth.IDLE_RPM, 0.0)
	await _settle(voice, EngineSynth.IDLE_RPM)
	t.gt(synth.frequency(), 0.0, "the fallback engine has a frequency")
	t.gt(synth.level(), 0.0, "and makes signal with no audio device")
	t.near(synth.rpm(), EngineSynth.IDLE_RPM, 1.0,
			"and reports the rpm it was given  (%.0f)" % synth.rpm())

	var open := synth.fade()
	synth.set_running(false)
	await _ticks(2)
	t.gt(open, 0.8, "a running synth is open  (%.3f)" % open)
	t.fails(synth.fade() > open * 0.5, "and closes when it stops  (%.3f)" % synth.fade())
	# ...and opens again, which is the transition the sample layers ride.
	synth.set_running(true)
	await _ticks(6)
	t.gt(synth.fade(), 0.8, "and opens again  (%.3f)" % synth.fade())


## The one new sound: the wastegate. It fires on a lift with boost in the pipe,
## it does not fire while the pedal is down, and it does not fire on a turbo
## that was never spooled. The thresholds are the car's, not invented.
func _the_wastegate_fires_on_a_lift(t: TestHarness) -> void:
	var voice := _voice()
	if not t.ok(voice != null, "an engine voice to blow off with"):
		return
	voice.set_redline(8000.0)
	voice.synth.cylinders = 4
	voice.synth.set_engine(4600.0, 1.0)
	voice.set_sounding(true)
	await _ticks(2)

	# Pedal down, boost climbing to full: that is a spool, not a lift.
	for i in 30:
		voice.set_boost(1.0, 1.0)
		await _ticks(1)
	t.fails(voice.flutter_playing(), "the pedal is still down, so no wastegate")

	# Lift off it: boost collapses in one frame with the throttle closed.
	voice.set_boost(0.4, 0.0)
	t.ok(voice.flutter_playing(), "the lift fires it")
	var wf := voice.get_node_or_null("Wastegate") as AudioStreamPlayer
	if t.ok(wf != null, "on its own player"):
		t.eq(wf.bus, AudioBuses.ENGINE, "which is the Engine bus")
		t.near(wf.volume_db, 0.0, 0.01,
				"and a full release is played at full  (%.1f dB)" % wf.volume_db)
		t.gt(wf.volume_db, SILENT, "well clear of silence")

	# Let it run out. The end is timed off the sample's own length in frames, not
	# waited on from the audio thread, so this is a real bound on the sound.
	await _ticks(30)
	t.fails(voice.flutter_playing(),
			"and it is over within half a second  (%.2f s)"
			% (EngineVoice.BLOWOFF_TAIL_S + 0.285))

	# A turbo that never spooled makes no noise worth hearing. `car_body.gd`
	# stops spooling at `throttle > 0.05`, which is where FLUTTER_LOAD comes from.
	for i in 4:
		voice.set_boost(0.0, 1.0)
		await _ticks(1)
		voice.set_boost(0.0, 0.0)
		await _ticks(1)
	t.fails(voice.flutter_playing(), "a turbo with nothing in it is silent")

	voice.set_sounding(false)
	await _ticks(3)
	t.fails(voice.flutter_playing(), "and stops with the engine")
	_free_voice()


# ------------------------------------------------------------- plumbing

## A voice of our own, so this suite measures the class rather than whatever the
## running game happens to have on the bus.
func _voice() -> EngineVoice:
	if _tree == null or _tree.root == null:
		return null
	var existing := _tree.root.find_child("T67Voice", true, false) as EngineVoice
	if existing != null:
		return existing
	var v := EngineVoice.new()
	v.name = "T67Voice"
	_tree.root.add_child(v)
	return v


## Taken out of the world again. The harness checks for nodes a suite left behind
## and tells the next one it inherited them, and a voice still playing its layers
## is worse than a leaked label.
func _free_voice() -> void:
	if _tree == null or _tree.root == null:
		return
	var v := _tree.root.find_child("T67Voice", true, false)
	if v != null:
		_tree.root.remove_child(v)
		v.free()
	await _tree.process_frame


## Spins until the synth's own rpm has caught up with what it was asked for.
## `EngineSynth` slews toward the target at the rate `car_body.gd` turns the
## crank, so reading a voice one frame after the revs change reads it mid-slew -
## still in the previous band. Bounded, because a slew that never arrives is a
## hang, and a hang inside a suite is the thing the harness is loudest about.
func _settle(voice: EngineVoice, rpm: float) -> void:
	for _i in 240:
		await _tree.process_frame
		if absf(voice.sounding_rpm() - rpm) < 1.0:
			await _tree.process_frame
			return


## The loudest of a `layer_state` volumes array - the layers that are up, not the
## ones parked at the floor.
func _peak_layer(volumes: Array) -> float:
	var best := -200.0
	for v in volumes:
		best = maxf(best, float(v))
	return best


## The roster's own cylinder count, from the audio service's table - the same map
## that tells a four from a six when the bridge pushes the revs across.
func _cylinders(id: String) -> int:
	if AudioService.CYLINDERS.has(id):
		return int(AudioService.CYLINDERS[id])
	return AudioService.DEFAULT_CYLINDERS


## Idle frames, not physics frames. `EngineVoice._process` is an idle callback -
## it is the thing that renders the synth and re-tracks the layers - so awaiting
## `_tree.physics_frame` does not reliably run it: under this harness 240 physics
## frames advanced the engine's own smoothing by about four renders, which is
## enough to read a voice mid-slew and conclude the wrong thing about it.
func _ticks(n: int) -> void:
	for _i in n:
		await _tree.process_frame