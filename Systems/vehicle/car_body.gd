class_name CarBody
extends RigidBody3D
## Raycast vehicle: 4 suspension struts + a friction-circle tyre model.
##
## Written rather than using Godot's built-in vehicle because the brief requires
## FWD / RWD / AWD to feel genuinely different, handbrake drifts, turbo lag, and
## tunable weight transfer. Owning the model is what makes that cheap to iterate.
##
## Sign conventions, in Godot 3D:  +X right, +Y up, -Z forward.
##
## Each physics step:
##   1. cast a ray straight down from each wheel mount
##   2. suspension force along the strut axis (this is the wheel load)
##   3. drive/brake torque -> wheel angular velocity -> slip ratio
##   4. slip angle from the contact patch velocity in the wheel frame
##   5. tyre forces, clamped by the friction circle
##   6. apply everything at the contact patch, plus the pitch/roll reaction

signal telemetry_changed(t: Dictionary)

const AIR_DENSITY := 1.2041
const G := 9.8
## How far a tyre rolls before it develops full force, in metres.
const SPEC_RELAXATION_LENGTH := 0.45
## Pedal travel that counts as a request, matching the 0.3 the forward path uses.
const PEDAL_ENGAGE := 0.3
## Reverse is brake-then-throttle, so how far the brake pedal has to be down.
const REVERSE_BRAKE := 0.3
## Below this road speed the car counts as stopped and may be put in reverse.
const REVERSE_ENTRY_SPEED := 1.0

@export var spec: CarSpec
## Build the exterior. Physics-only runs (and a couple of headless benches) can
## turn this off; in the game every car is seen.
@export var build_visual := true

## The exterior this body is wearing, if any. Null when `build_visual` is off.
var visual: CarVisual = null

# --- driver inputs (set by the player controller or the AI) ---
var throttle := 0.0
var brake := 0.0
var steer := 0.0        ## -1 (full right) .. +1 (full left). Positive yaws toward
                        ## -X from a -Z heading, because the wheel basis is
                        ## rotated about +Y (see the steering block below).
                        ## This was documented as the opposite for a while.
var handbrake := 0.0

# --- drivetrain state ---
var engine_rpm := 850.0
var current_gear := 1     ## -1 reverse, 0 neutral, 1..n forward
var boost := 0.0          ## 0..1 turbo spool
var shift_timer := 0.0
var engine_torque := 0.0  ## Nm at the crank, after boost and redline cut

# --- readouts for HUD / AI / audio ---
var speed_mps := 0.0
var speed_kph := 0.0
var slip_angle_body := 0.0
var wheels_on_ground := 0
var wheelspin := 0.0
var extra_grip := 0.0     ## from downforce, as a fraction of g

var _wheels: Array = []
var _telemetry_tick := 0


func _ready() -> void:
	if spec == null:
		spec = CarSpec.new()
	# Cars collide with the world and with each other. Ground contact itself comes
	# from the suspension rays, not this shape - the shape's job is car-to-car
	# contact AND, critically, giving the solver a real inertia tensor. Without a
	# shape the body has effectively zero rotational inertia and any asymmetric
	# force spins it like a top.
	collision_layer = 2
	collision_mask = 1 | 2 | 3
	mass = spec.mass
	# Centre of mass: the highest-leverage handling parameter on a street car.
	# The body origin sits at hub height, so the CoG offset is measured from
	# there: `cg_height` above the contact patch, shifted rearward by mass_bias_z.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, cg_height_offset(), spec.mass_bias_z)
	angular_damp = 0.4
	linear_damp = 0.0
	continuous_cd = true
	_build_collision_shape()
	_build_wheels()
	if build_visual:
		visual = CarVisual.new()
		visual.name = "Visual"
		add_child(visual)
		visual.build(spec)
	reset_to(spec.start_position, spec.start_rotation)


## Chassis box, sitting above the origin so its underside clears the road at
## full droop. The suspension rays, not this shape, carry the car's weight.
func _build_collision_shape() -> void:
	for c in get_children():
		if c is CollisionShape3D:
			c.queue_free()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(spec.body_width * 0.92, spec.body_height, spec.body_length * 0.92)
	shape.shape = box
	shape.position = Vector3(0.0, spec.body_height * 0.5, 0.0)
	add_child(shape)


func _build_wheels() -> void:
	_wheels.clear()
	var half_base := spec.wheelbase * 0.5
	var half_track := spec.track_width * 0.5
	var layout := [
		{"name": "FL", "pos": Vector3(-half_track, 0.0, -half_base), "front": true, "side": -1.0},
		{"name": "FR", "pos": Vector3(half_track, 0.0, -half_base), "front": true, "side": 1.0},
		{"name": "RL", "pos": Vector3(-half_track, 0.0, half_base), "front": false, "side": -1.0},
		{"name": "RR", "pos": Vector3(half_track, 0.0, half_base), "front": false, "side": 1.0},
	]
	for w in layout:
		_wheels.append({
			"name": w["name"],
			"mount": w["pos"],                 ## strut top, in body space
			"front": w["front"],
			"side": w["side"],
			"radius": spec.tyre_radius,
			"rest": spec.suspension_rest,
			"travel": spec.suspension_travel,
			"omega": 0.0,                      ## rad/s
			"load": 0.0,                       ## N of vertical wheel load
			"contact": false,
			"contact_point": Vector3.ZERO,
			"contact_normal": Vector3.UP,
			"compression": 0.0,
			"slip_ratio": 0.0,
			"slip_angle": 0.0,
			"sr_smooth": 0.0,
			"fx": 0.0,
			"fy": 0.0,
			"spin_vis": 0.0,                  ## radians, for the visual wheel mesh
			"steer_angle": 0.0,
			"surface_mu": 1.0,
		})


func reset_to(pos: Vector3, rot: Vector3) -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	rotation = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = Transform3D(Basis.from_euler(rot), pos)
	engine_rpm = spec.idle_rpm
	current_gear = 1
	boost = 0.0
	shift_timer = 0.0
	for w in _wheels:
		w["omega"] = 0.0
		w["spin_vis"] = 0.0
		w["load"] = 0.0


func get_wheel(wheel_name: String) -> Dictionary:
	for w in _wheels:
		if w["name"] == wheel_name:
			return w
	return {}


func wheels() -> Array:
	return _wheels


func forward() -> Vector3:
	return -global_transform.basis.z


## Vertical CoM offset in body space. The origin is at hub height (tyre_radius
## above the ground at rest), so this converts "CoG height above the road" into a
## body-space offset.
func cg_height_offset() -> float:
	return spec.cg_height - spec.tyre_radius


func right() -> Vector3:
	return global_transform.basis.x


## The car's up axis in world space.
func car_up() -> Vector3:
	return global_transform.basis.y


func is_driving_wheel(w: Dictionary) -> bool:
	match spec.drive:
		"rwd": return not w["front"]
		"fwd": return w["front"]
		"awd": return true
	return false


## Ratio for one gear, signed. `gears` has no reverse entry, so reverse borrows
## first gear's ratio with the sign flipped - the old `g < 0 -> 0.0` made reverse
## a gear that made no torque at all, so selecting it moved nothing. Every caller
## wants a positive magnitude except the drive torque, which is exactly where the
## sign belongs.
func gear_ratio(g: int) -> float:
	if g == -1:
		return -float(spec.gears[1]) if spec.gears.size() > 1 else 0.0
	if g < 0 or g >= spec.gears.size():
		return 0.0
	return float(spec.gears[g])


## Fraction of drive torque sent to an axle. Front-drive, rear-drive and
## all-wheel-drive are just three different answers to this question.
func _axle_share(front: bool) -> float:
	match spec.drive:
		"fwd": return 1.0 if front else 0.0
		"rwd": return 0.0 if front else 1.0
		"awd": return (1.0 - spec.torque_split) if front else spec.torque_split
	return 0.0


func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_update_telemetry()
	_update_suspension()
	_update_engine(delta)
	_update_tyres(delta)
	_apply_aero()


# ----------------------------------------------------------------- telemetry
func _update_telemetry() -> void:
	speed_mps = linear_velocity.length()
	speed_kph = speed_mps * 3.6
	if speed_mps > 1.0:
		slip_angle_body = atan2(linear_velocity.dot(right()), maxf(absf(linear_velocity.dot(forward())), 0.8))
	else:
		slip_angle_body = 0.0

	_telemetry_tick += 1
	if _telemetry_tick % 6 == 0:
		telemetry_changed.emit({
			"kph": speed_kph, "rpm": engine_rpm, "gear": current_gear,
			"boost": boost, "slip": slip_angle_body,
			"wheels_on_ground": wheels_on_ground, "wheelspin": wheelspin,
		})


# ---------------------------------------------------------------- suspension
func _update_suspension() -> void:
	var space := get_world_3d().direct_space_state
	var inv_basis := global_transform.basis.orthonormalized().transposed()
	wheels_on_ground = 0

	for w in _wheels:
		# The hub sits at the mount point; the strut extends `rest` above it, so the
		# strut top is the ray origin. At full droop the hub is `rest` below the
		# strut top, and the tyre touches ground when that gap is `radius`.
		var top: Vector3 = w["mount"] + Vector3(0.0, w["rest"], 0.0)
		var mount_world := global_transform * top
		# Cast along the body's local down so a rolled car gets rolled struts.
		var axis_down := (inv_basis * Vector3.DOWN).normalized()
		var reach: float = w["radius"] + w["rest"] + 0.30
		var query := PhysicsRayQueryParameters3D.create(mount_world, mount_world + axis_down * reach)
		query.collision_mask = 1
		query.exclude = [get_rid()]

		var hit := space.intersect_ray(query)
		if hit.is_empty():
			w["contact"] = false
			w["load"] = 0.0
			w["compression"] = 0.0
			continue

		wheels_on_ground += 1
		var point: Vector3 = hit["position"]
		var dist := mount_world.distance_to(point)
		var axis_len := axis_down.length()   # 1.0, but keep it explicit
		var along_axis: float = dist / axis_len
		var compress: float = clampf(w["rest"] - (along_axis - w["radius"]), 0.0, w["travel"])
		w["compression"] = compress
		w["contact"] = true
		w["contact_point"] = point
		w["contact_normal"] = hit["normal"]

		# Negative velocity along the strut axis means the strut is compressing.
		var vel_along_axis: float = linear_velocity.dot(axis_down)
		var force := TyreModel.suspension(along_axis, w["rest"] + w["radius"], vel_along_axis,
			spec.spring_rate, spec.damper, w["travel"])
		# A wheel in the air carries no load; a fully topped-out strut pushes none.
		w["load"] = maxf(force, 0.0)
		if w["load"] > 0.0:
			# The strut pushes the chassis UP, i.e. opposite the cast direction.
			apply_force(-axis_down * w["load"], point - global_position)

	_apply_anti_roll("FL", "FR")
	_apply_anti_roll("RL", "RR")


## Anti-roll bar: resists the difference in compression across an axle. Cheaper
## and more predictable than letting the car lean on tyre stiffness alone, and it
## is a large part of why the car feels planted rather than wallowy.
func _apply_anti_roll(a_name: String, b_name: String) -> void:
	var a := get_wheel(a_name)
	var b := get_wheel(b_name)
	if a.is_empty() or b.is_empty():
		return
	if not a["contact"] and not b["contact"]:
		return
	var delta_comp: float = float(a["compression"]) - float(b["compression"])
	if absf(delta_comp) < 0.0005:
		return
	# Signed: push the more-compressed wheel up and its partner down. Clamping
	# this to one sign turns the bar into a one-way shove that rolls the car.
	var arb_force: float = clampf(delta_comp * spec.anti_roll, -8000.0, 8000.0)
	var up := car_up()
	if a["contact"]:
		apply_force(up * arb_force, a["contact_point"] - global_position)
	if b["contact"]:
		apply_force(-up * arb_force, b["contact_point"] - global_position)


# -------------------------------------------------------------------- engine
func _update_engine(delta: float) -> void:
	_update_turbo(delta)

	if shift_timer > 0.0:
		shift_timer = maxf(shift_timer - delta, 0.0)

	# Engine speed follows the driven wheels through the gearing, with a floor at
	# a throttle-dependent idle so the car cannot stall while stationary and the
	# tacho still reads sensibly.
	var driven_wheel_omega := 0.0
	var driven := 0
	for w in _wheels:
		if is_driving_wheel(w):
			driven_wheel_omega += w["omega"]
			driven += 1
	if driven == 0:
		driven = 1
	driven_wheel_omega /= driven

	var ratio := gear_ratio(current_gear) * spec.final_drive
	# absf: reverse's ratio is negative but the tacho reads engine speed, which the
	# wheels drive either way round.
	var geared_rpm: float = absf(driven_wheel_omega) * absf(ratio) * 60.0 / TAU
	var free_rpm: float = spec.idle_rpm + throttle * (spec.redline - spec.idle_rpm) * 0.55
	var target_rpm: float = maxf(geared_rpm, free_rpm)

	if absf(geared_rpm - target_rpm) < 500.0:
		engine_rpm = lerpf(engine_rpm, target_rpm, clampf(delta * 16.0, 0.0, 1.0))
	else:
		# Sharp drop when the clutch drops / a gear is selected.
		engine_rpm = move_toward(engine_rpm, target_rpm, delta * 6000.0)
	engine_rpm = clampf(engine_rpm, spec.idle_rpm * 0.5, spec.redline * 1.02)

	# Natural rev limiter: cut torque over the last 250 rpm rather than letting
	# the curve run past the redline.
	var cut := 1.0
	if engine_rpm > spec.redline - 250.0:
		cut = clampf((spec.redline - engine_rpm) / 250.0, 0.0, 1.0)

	var na_torque := TyreModel.torque_from_curve(spec.torque_curve, engine_rpm)
	var engine_brake := 0.0
	if throttle < 0.05:
		engine_brake = spec.engine_brake_torque * (engine_rpm / maxf(spec.redline, 1.0))

	engine_torque = maxf(na_torque * (1.0 + boost * spec.turbo_boost_multiplier) * throttle - engine_brake, 0.0) * cut


func _update_turbo(delta: float) -> void:
	if not spec.has_turbo:
		boost = move_toward(boost, 0.0, delta * 6.0)
		return
	# First-order turbo lag. Spool time shortens as revs climb past the threshold,
	# because the compressor outruns demand - this is what makes a big single
	# feel like it comes alive in one pull.
	var headroom: float = clampf((engine_rpm - spec.turbo_threshold_rpm) / 2500.0, 0.0, 1.0)
	if throttle > 0.05 and engine_rpm > spec.turbo_threshold_rpm:
		var tau: float = maxf(spec.turbo_spool_time * (1.0 - 0.55 * headroom), 0.02)
		boost = move_toward(boost, throttle, delta / tau)
	else:
		boost = move_toward(boost, 0.0, delta / maxf(spec.turbo_blowoff_time, 0.02))


func shift_up() -> bool:
	# `>= -1` so a manual box can paddle out of reverse. It could not before only
	# because reverse was unreachable; now that it is selectable, refusing to
	# leave it would strand the car there.
	if current_gear < spec.gears.size() - 1 and shift_timer <= 0.0 and current_gear >= -1:
		current_gear += 1
		shift_timer = spec.shift_time
		return true
	return false


func shift_down() -> bool:
	if current_gear > -1 and shift_timer <= 0.0:
		current_gear -= 1
		shift_timer = spec.shift_time
		return true
	return false


## Picks the gear that suits road speed. Used by the AI and available to the
## player; the manual paddles above still work if they want them.
##
## Reverse is brake-then-throttle at a standstill - hold the brake at a stop, then
## press the throttle, which is what the keyboard already means (S then W). Throttle
## on its own deliberately does NOT select reverse: a car that coasts up to a kerb
## with the throttle still down would flip into reverse the moment it stopped and
## drive back into the thing it just parked at. Measured: a stopped car sits at
## 0.08 m/s and a car braking from 60 kph is under 1.1 m/s within one frame, so the
## 1.0 m/s entry speed is an order of magnitude clear of the noise floor while
## still reading as "stopped" to a player.
##
## ponytail: reverse is geared like 1st, so it runs to the 1st-gear redline -
## measured 65 kph backwards, where a real reverse gear is capped nearer 25. No
## limiter is added here because none of the forward gears have one either and the
## player can always lift; cap the rev limiter on `current_gear < 0` if reverse
## ever needs a ceiling of its own.
func auto_shift() -> void:
	if shift_timer > 0.0:
		return
	# Reverse, from any forward gear. Not inside the `current_gear <= 0` branch
	# below: the box never sits below 1st on its own, so that branch is never
	# reached in auto and putting it there is how reverse stayed unreachable.
	if current_gear >= 0 and brake > REVERSE_BRAKE and throttle > PEDAL_ENGAGE \
			and speed_mps <= REVERSE_ENTRY_SPEED:
		current_gear = -1
		shift_timer = spec.shift_time
		return
	if current_gear <= 0:
		# `brake <= REVERSE_BRAKE` so that holding both pedals - the request that
		# selected reverse - cannot also bounce the box straight back to 1st.
		if throttle > PEDAL_ENGAGE and brake <= REVERSE_BRAKE:
			current_gear = 1
			shift_timer = spec.shift_time
		return
	# Decide on ROAD speed, not wheel speed. Using wheel speed means a wheelspinning
	# launch runs the box up to top gear in second and the car then bogs.
	var road_omega: float = speed_mps / maxf(spec.tyre_radius, 0.05)
	var rpm_in_gear: float = road_omega * gear_ratio(current_gear) * spec.final_drive * 60.0 / TAU
	if rpm_in_gear > spec.shift_up_rpm and current_gear < spec.gears.size() - 1:
		shift_up()
	elif rpm_in_gear < spec.shift_down_rpm and current_gear > 1:
		shift_down()


# --------------------------------------------------------------------- tyres
func _update_tyres(delta: float) -> void:
	var basis := global_transform.basis
	var steer_lock := _steer_lock()

	# While the box is in reverse and the player is asking to reverse, the brake
	# pedal is the reverse request, not the brake - that is the only way to ask for
	# reverse in the first place (see auto_shift). Left on, it cancels the reverse
	# drive torque almost exactly: measured 5663 Nm to the rear axle against 2650 Nm
	# of brake per wheel left the tyres spinning at 0.12 rad/s and the car creeping
	# backwards at 0.02 m/s. Off the throttle, S is an ordinary brake again, which
	# is how a reversing car stops.
	var pedal_brake := 0.0 if (current_gear < 0 and throttle > PEDAL_ENGAGE) else brake

	# Torque at the crank reaches the wheels through the box and final drive, then
	# splits across the driven axles by layout. This is the single most important
	# line in the car: it is why a front-drive econobox and an all-wheel-drive
	# turbo do not behave alike.
	var front_n := 0
	var rear_n := 0
	for w in _wheels:
		if is_driving_wheel(w):
			if w["front"]:
				front_n += 1
			else:
				rear_n += 1
	var front_share := _axle_share(true) / float(maxi(front_n, 1))
	var rear_share := _axle_share(false) / float(maxi(rear_n, 1))

	wheelspin = 0.0

	for w in _wheels:
		# Speed-sensitive lock plus Ackermann: the inside wheel turns more.
		var steer_angle := 0.0
		if w["front"]:
			# `steer * side` is negative for the inside wheel in either direction, so
			# Ackermann lengthens the inside wheel's angle and shortens the outside.
			var ackermann: float = 1.0 + spec.ackermann * steer * float(w["side"])
			steer_angle = steer * spec.max_steer * steer_lock * ackermann
		w["steer_angle"] = steer_angle

		var wheel_basis := basis.rotated(Vector3.UP, steer_angle)
		var fwd := -wheel_basis.z
		var side := wheel_basis.x
		var v_forward := linear_velocity.dot(fwd)
		var v_side := linear_velocity.dot(side)

		# Brake torque for this wheel. The handbrake locks the rear axle only.
		var brake_torque := pedal_brake * spec.brake_torque
		if w["front"]:
			brake_torque *= spec.brake_bias
		if handbrake > 0.0 and not w["front"]:
			brake_torque = maxf(brake_torque, handbrake * spec.handbrake_torque)

		# Drive torque for this wheel (zero while shifting - the clutch is out).
		var drive_torque := 0.0
		if is_driving_wheel(w) and shift_timer <= 0.0:
			var share: float = front_share if w["front"] else rear_share
			drive_torque = engine_torque * spec.final_drive * gear_ratio(current_gear) * share

		if not w["contact"]:
			# Airborne: only drive torque and bearing drag act on the wheel.
			_integrate_wheel(w, drive_torque, 0.0, 0.0, delta)
			w["fx"] = 0.0
			w["fy"] = 0.0
			w["slip_ratio"] = 0.0
			w["slip_angle"] = 0.0
			w["sr_smooth"] = 0.0
			w["spin_vis"] = fposmod(w["spin_vis"] + w["omega"] * delta, TAU)
			continue

		var load: float = w["load"]
		var mu: float = spec.tyre_peak_mu * float(w["surface_mu"])
		var radius: float = w["radius"]

		var sr := TyreModel.slip_ratio(w["omega"] * radius, v_forward)
		var sat := TyreModel.slip_angle_tan(v_forward, v_side)

		# Relaxation length: a real tyre carcass takes a few tens of centimetres
		# of rolling to build its force. Without this the slip ratio flickers
		# violently at low speed, where the EPS_SPEED denominator makes tiny
		# velocity errors look like huge slip, and the car chatters in a straight
		# line. Physically motivated and it is what stops the car buzzing.
		var roll_speed: float = maxf(absf(v_forward), 2.0)
		var blend: float = clampf(roll_speed * delta / SPEC_RELAXATION_LENGTH, 0.0, 1.0)
		var sr_smooth: float = lerp(float(w["sr_smooth"]), sr, blend)
		w["sr_smooth"] = sr_smooth
		w["slip_ratio"] = sr_smooth
		w["slip_angle"] = atan(sat)

		var fx := TyreModel.longitudinal(sr_smooth, load, mu)
		# lateral() already returns force opposing the slip, so no sign flip here.
		var fy := TyreModel.lateral(sat, load, mu)

		# Friction circle: combined demand cannot exceed peak grip. Without this a
		# car can brake and corner at full grip at once, which is the classic tell
		# of a fake arcade drift model.
		var clamped := TyreModel.friction_circle(fx, fy, mu * load)
		fx = clamped.x
		fy = clamped.y
		w["fx"] = fx
		w["fy"] = fy

		if load > 100.0 and absf(sr) > 0.35:
			wheelspin = maxf(wheelspin, absf(sr))

		# A fully locked tyre cannot also corner.
		if brake_torque > 0.0 and absf(w["omega"]) < 0.8:
			fy *= 0.2

		apply_force(fwd * fx + side * fy, w["contact_point"] - global_position)

		# The tyre's longitudinal force reacts back onto the wheel's rotation.
		# Without this a free-rolling wheel never spins up to match road speed,
		# so the tyre model sees a huge slip ratio at a standstill and brakes the
		# car against its own engine. It is also what makes wheelspin self-limiting.
		_integrate_wheel(w, drive_torque, brake_torque, fx, delta)

		w["spin_vis"] = fposmod(w["spin_vis"] + w["omega"] * delta, TAU)


## Integrates one wheel's spin. `tyre_fx` is the longitudinal force the tyre is
## applying to the road, which reacts as `-fx * radius` back into the wheel.
## Brakes can lock a wheel (threshold braking, handbrake slides) but can never
## drive it backwards.
func _integrate_wheel(w: Dictionary, drive_torque: float, brake_torque: float,
		tyre_fx: float, delta: float) -> void:
	var inertia: float = spec.wheel_inertia + float(w["load"]) * 0.0006
	var radius: float = w["radius"]
	var omega: float = w["omega"]
	omega += ((drive_torque - tyre_fx * radius) / maxf(inertia, 0.01)) * delta
	var brake_delta: float = (brake_torque / maxf(inertia, 0.01)) * delta
	if brake_delta > 0.0:
		if absf(omega) <= brake_delta:
			omega = 0.0
		else:
			omega -= signf(omega) * brake_delta
	# Rolling resistance / bearing drag, so a car in the air does not spin forever.
	omega -= omega * spec.bearing_drag * delta
	w["omega"] = clampf(omega, -400.0, 400.0)


func _steer_lock() -> float:
	# Full lock at parking speed, tapering to roughly a third at high speed so the
	# car is not twitchy at 140 km/h.
	var t: float = clampf(speed_mps / 32.0, 0.0, 1.0)
	return lerpf(1.0, 0.32, t * t)


# ---------------------------------------------------------------------- aero
func _apply_aero() -> void:
	var v := linear_velocity
	var speed := v.length()
	if speed < 0.5:
		extra_grip = 0.0
		return
	apply_force(-v.normalized() * (0.5 * AIR_DENSITY * spec.drag_area * spec.drag_coefficient * speed * speed), Vector3.ZERO)

	# Downforce adds load, which adds grip, in the fast corners.
	var df: float = 0.5 * AIR_DENSITY * spec.lift_area * spec.downforce_coefficient * speed * speed
	if df > 1.0:
		apply_force(Vector3.DOWN * df, Vector3(0.0, 0.5, 0.0))
		extra_grip = df / (mass * G)
	else:
		extra_grip = 0.0


func power_to_weight() -> float:
	return spec.peak_power_kw() / (spec.mass / 1000.0)
