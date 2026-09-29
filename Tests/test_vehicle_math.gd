extends RefCounted
## Pure tyre-model checks. No scene tree needed - these are the numbers the
## whole driving feel rests on, so they are pinned here.

func run(t: TestHarness) -> void:
	_longitudinal_peak(t)
	_lateral_peak(t)
	_friction_circle(t)
	_suspension(t)
	_torque_curve(t)
	_slip_math(t)


func _longitudinal_peak(t: TestHarness) -> void:
	var load := 3000.0
	# Grip rises from zero, peaks somewhere plausible, then falls away past the peak.
	var near_zero := TyreModel.longitudinal(0.0, load, 1.0)
	t.near(near_zero, 0.0, 1.0, "longitudinal force is zero at zero slip")

	var peak := 0.0
	var peak_at := 0.0
	for i in range(1, 400):
		var sr := float(i) * 0.01   # 0 .. 4
		var f := TyreModel.longitudinal(sr, load, 1.0)
		if f > peak:
			peak = f
			peak_at = sr
	t.between(peak_at, 0.05, 0.35, "longitudinal peak slip ratio in a sane band")
	t.gt(peak, 2500.0, "peak traction scales with load and mu")

	# Must fall away past the peak, or the car has infinite grip at any wheelspin.
	var at_peak := TyreModel.longitudinal(peak_at, load, 1.0)
	var far := TyreModel.longitudinal(2.5, load, 1.0)
	t.fails(far >= at_peak, "grip falls away past the peak (no infinite wheelspin)")

	# Load sensitivity: doubling load more than doubles grip in reality, but the
	# key property is monotonicity.
	t.gt(TyreModel.longitudinal(0.15, 6000.0, 1.0), TyreModel.longitudinal(0.15, 3000.0, 1.0),
		"more load gives more grip")


func _lateral_peak(t: TestHarness) -> void:
	var load := 3000.0
	t.near(TyreModel.lateral(0.0, load, 1.0), 0.0, 1.0, "lateral force is zero at zero slip angle")

	# The force opposes the slip, so it is negative for a rightward slip angle.
	# Measure the peak on the magnitude.
	var peak := 0.0
	var peak_at := 0.0
	for i in range(1, 600):
		var sa := float(i) * 0.005   # up to 3.0
		var f: float = absf(TyreModel.lateral(sa, load, 1.0))
		if f > peak:
			peak = f
			peak_at = sa
	t.between(peak_at, 0.05, 0.30, "lateral peak slip angle in a sane band (rad)")
	t.gt(peak, 2500.0, "lateral peak scales with load")

	# Antisymmetry: a slip to the right must produce a force to the left.
	t.near(TyreModel.lateral(0.2, load, 1.0), -TyreModel.lateral(-0.2, load, 1.0), 1.0,
		"lateral force is antisymmetric about zero slip")

	# Past the peak the force must still oppose the slip, otherwise the car will
	# happily hold a slide forever instead of washing out.
	t.fails(TyreModel.lateral(2.0, load, 1.0) > 0.0, "large slip angle still pushes back")
	# And it must retain a sensible share of grip, which is what makes a
	# handbrake slide holdable.
	var tail: float = absf(TyreModel.lateral(2.0, load, 1.0)) / absf(TyreModel.lateral(0.13, load, 1.0))
	t.between(tail, 0.5, 0.95, "a fully sliding tyre keeps a holdable share of grip")


func _friction_circle(t: TestHarness) -> void:
	var limit := 3000.0
	var inside := TyreModel.friction_circle(1000.0, 1000.0, limit)
	t.near(inside.length(), sqrt(2.0) * 1000.0, 1.0, "demand inside the circle is untouched")

	var outside := TyreModel.friction_circle(4000.0, 3000.0, limit)
	t.near(outside.length(), limit, 1.0, "demand outside the circle is clamped to the limit")

	# Direction must be preserved, otherwise clamping rotates the force vector
	# and the car pulls sideways under braking.
	t.near(outside.normalized().angle_to(Vector2(4000.0, 3000.0).normalized()), 0.0, 0.001,
		"clamping preserves force direction")

	t.eq(TyreModel.friction_circle(0.0, 0.0, limit), Vector2.ZERO, "zero demand stays zero")
	t.eq(TyreModel.friction_circle(5000.0, 0.0, 0.0), Vector2.ZERO, "zero limit yields zero force")


func _suspension(t: TestHarness) -> void:
	# rest_length 0.44, travel 0.16, at full droop the strut is at rest_length:
	# zero force. Fully compressed: maximum force.
	var at_droop := TyreModel.suspension(0.44, 0.44, 0.0, 34000.0, 3600.0, 0.16)
	t.near(at_droop, 0.0, 1.0, "strut pushes nothing at full droop")

	var at_hard := TyreModel.suspension(0.28, 0.44, 0.0, 34000.0, 3600.0, 0.16)
	t.gt(at_hard, 4000.0, "strut pushes hard when compressed")

	# A damper always opposes relative motion, so it ADDS force while the strut
	# compresses and REMOVES force while it extends. velocity_along_axis is along
	# the strut's DOWN axis, so positive = the chassis is descending = compressing.
	var static_f := TyreModel.suspension(0.36, 0.44, 0.0, 34000.0, 3600.0, 0.16)
	var compressing := TyreModel.suspension(0.36, 0.44, 1.0, 34000.0, 3600.0, 0.16)
	var extending := TyreModel.suspension(0.36, 0.44, -1.0, 34000.0, 3600.0, 0.16)
	t.gt(compressing, static_f, "damping pushes back against a compressing strut")
	t.fails(extending >= static_f, "damping holds back a drooping strut")
	# Equal and opposite: damping alone is a pure velocity-dependent term.
	t.near(compressing - static_f, static_f - extending, 1.0,
		"damping contributes symmetrically in compression and extension")

	# Never negative: a strut cannot pull the car down, however fast it droops.
	t.eq(TyreModel.suspension(0.30, 0.44, -6.0, 34000.0, 3600.0, 0.16), 0.0,
		"suspension force is clamped at zero, never negative")

	# Progressive: the last 10% of travel must be stiffer than the first 10%.
	var first := TyreModel.suspension(0.44 - 0.016, 0.44, 0.0, 34000.0, 0.0, 0.16)
	var last := TyreModel.suspension(0.44 - 0.152, 0.44, 0.0, 34000.0, 0.0, 0.16)
	var first_rate := first / 0.016
	var last_rate := last / 0.152
	t.gt(last_rate, first_rate, "spring rate is progressive (stiffer at the bottom)")


func _torque_curve(t: TestHarness) -> void:
	var curve := [[800, 100.0], [3000, 200.0], [6000, 180.0]]
	t.near(TyreModel.torque_from_curve(curve, 800.0), 100.0, 0.01, "curve returns the first point at its rpm")
	t.near(TyreModel.torque_from_curve(curve, 3000.0), 200.0, 0.01, "curve peaks at its defined rpm")
	t.near(TyreModel.torque_from_curve(curve, 6000.0), 180.0, 0.01, "curve returns the last point at its rpm")
	t.near(TyreModel.torque_from_curve(curve, 1900.0), 150.0, 0.01, "curve interpolates linearly between points")
	# Clamped outside the defined range - a car must not gain a torque spike.
	t.near(TyreModel.torque_from_curve(curve, 100.0), 100.0, 0.01, "curve clamps below its range")
	t.near(TyreModel.torque_from_curve(curve, 9000.0), 180.0, 0.01, "curve clamps above its range")
	t.eq(TyreModel.torque_from_curve([], 3000.0), 0.0, "empty curve yields no torque")

	# Every shipped car must produce a sane, strictly-positive torque curve.
	for id in CarDB.ALL_IDS:
		var spec := CarDB.get_spec(id)
		var peak := TyreModel.torque_from_curve(spec.torque_curve, spec.redline * 0.8)
		t.gt(peak, 50.0, "%s produces usable torque before the redline" % id)
		t.gt(spec.peak_torque_nm(), peak, "%s boost raises peak torque" % id)


func _slip_math(t: TestHarness) -> void:
	# Wheel spinning faster than the road = positive slip ratio.
	t.gt(TyreModel.slip_ratio(20.0, 10.0), 0.0, "overspinning wheel gives positive slip ratio")
	t.fails(TyreModel.slip_ratio(10.0, 20.0) > 0.0, "rolling wheel in freewheel gives no positive slip")

	# Slip angle: sliding sideways gives a slip angle with the sign of the slide.
	t.gt(TyreModel.slip_angle_tan(10.0, 2.0), 0.0, "sliding right gives positive slip angle")
	t.fails(TyreModel.slip_angle_tan(10.0, -2.0) > 0.0, "sliding left gives negative slip angle")

	# Guard rails: no division blow-ups at a standstill.
	t.ok(is_finite(TyreModel.slip_ratio(0.0, 0.0)), "slip ratio is finite at zero speed")
	t.ok(is_finite(TyreModel.slip_angle_tan(0.0, 0.0)), "slip angle is finite at zero speed")
	t.ok(is_finite(TyreModel.slip_angle_tan(0.001, 5.0)), "slip angle is finite when crawling sideways")
