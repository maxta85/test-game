class_name TyreModel
extends RefCounted
## Tyre force model.
##
## Deliberately NOT a fitted Pacejka curve. A magic formula's B/C/E constants are
## hard to reason about and easy to mis-tune into a curve that asymptotes to full
## grip at 70 degrees of slip - which is exactly what the first attempt here did,
## and it made the car un-driveable. What actually matters for feel is three
## numbers, so those are the knobs:
##
##   peak_slip  - slip at which the tyre makes most force
##   tail_ratio - fraction of peak grip still available once the tyre is sliding
##   stiffness  - how quickly force builds up to the peak
##
## The shape is fixed and correct: smooth rise to the peak, then a smooth decay
## toward the sliding-grip plateau. The tail is what makes a handbrake slide
## holdable instead of snapping straight back.

const EPS_SPEED := 1.2

## Grip plateaus reached once the tyre is fully sliding.
const LATERAL_TAIL := 0.72      ## a sliding tyre keeps most of its cornering force
const LONGITUDINAL_TAIL := 0.80 ## a locked or spinning tyre keeps most of its drag

## Slip (as a fraction of peak_slip) at which the tail decay has mostly settled.
const TAIL_DECAY := 0.55


## Normalised grip 0..1 as a function of |slip| / peak_slip.
## Reaches exactly 1.0 at the peak, then decays smoothly to `tail`.
static func shape(slip: float, peak_slip: float, tail: float) -> float:
	if peak_slip <= 0.0:
		return 0.0
	var x: float = absf(slip) / peak_slip
	if x <= 1.0:
		# Smooth rise with zero gradient at the peak, so there is no kink where
		# the tyre transitions from gripping to sliding.
		return sin(x * PI * 0.5)
	return tail + (1.0 - tail) * exp(-TAIL_DECAY * (x - 1.0))


## Longitudinal force in newtons. Positive slip ratio (wheel spinning faster than
## the road) produces a positive, driving force; negative slip (locked wheel, or
## braking) produces a negative force. The sign matters: a locked wheel must
## retard the car, not push it.
static func longitudinal(slip_ratio: float, load: float, peak_mu: float, peak_slip: float = 0.14) -> float:
	if load <= 0.0:
		return 0.0
	return signf(slip_ratio) * peak_mu * load * shape(slip_ratio, peak_slip, LONGITUDINAL_TAIL)


## Lateral force in newtons, opposing the direction of travel across the tyre.
## Negative for a rightward slip angle, positive for a leftward one.
static func lateral(slip_angle_tan: float, load: float, peak_mu: float, peak_slip: float = 0.13) -> float:
	if load <= 0.0:
		return 0.0
	return -peak_mu * load * signf(slip_angle_tan) * shape(slip_angle_tan, peak_slip, LATERAL_TAIL)


## Longitudinal slip ratio from wheel and ground speeds.
## `wheel_speed` is the circumferential speed at the contact patch (omega * radius).
static func slip_ratio(wheel_speed: float, ground_speed: float) -> float:
	return (wheel_speed - ground_speed) / maxf(absf(ground_speed), EPS_SPEED)


## Tangent of the slip angle from the contact patch velocity in the wheel frame.
## `v_forward` is the component along the wheel heading, `v_side` is lateral.
static func slip_angle_tan(v_forward: float, v_side: float) -> float:
	return v_side / maxf(absf(v_forward), EPS_SPEED)


## Combines longitudinal and lateral demand onto a friction ellipse.
##
## Without this a car can brake and corner at full grip simultaneously, which is
## the single biggest tell of a fake arcade drift model. Scale down so
## sqrt(fx^2 + fy^2) never exceeds the tyre's peak.
static func friction_circle(fx: float, fy: float, limit: float) -> Vector2:
	var mag := sqrt(fx * fx + fy * fy)
	if mag <= limit or mag <= 0.0001:
		return Vector2(fx, fy)
	return Vector2(fx, fy) * (limit / mag)


## Suspension force along the strut axis for a raycast strut.
##
## `velocity_along_axis` is the chassis velocity measured along the strut's DOWN
## axis. Positive means the chassis is descending, which (with the wheel on
## stationary ground) means the strut is COMPRESSING. The damping term is
## therefore added: it both increases force when the strut compresses and
## decreases it when the strut extends, so it always opposes relative motion.
## Getting this sign wrong is not a subtle error - it turns the damper into
## positive feedback and the car launches itself off the road.
##
## Progressive: past ~60% compression the spring stiffens, which is what stops a
## bottomed-out strut from launching the car and gives weight transfer its
## characteristic settle under braking.
static func suspension(distance_to_wheel: float, rest_length: float, velocity_along_axis: float,
		stiffness: float, damping: float, travel: float) -> float:
	var compress: float = clampf(rest_length - distance_to_wheel, 0.0, maxf(travel, 0.0))
	if compress <= 0.0:
		return 0.0
	var ratio: float = compress / maxf(travel, 0.001)
	var progressive: float = stiffness * (1.0 + 1.8 * ratio * ratio)
	var force: float = progressive * compress + damping * velocity_along_axis
	return maxf(force, 0.0)


## Engine torque at a given rpm from a piecewise-linear [[rpm, Nm], ...] curve.
## Clamps at both ends so a bad curve cannot produce a spike.
static func torque_from_curve(curve: Array, rpm: float) -> float:
	if curve.is_empty():
		return 0.0
	if rpm <= float(curve[0][0]):
		return float(curve[0][1])
	var last: Array = curve[curve.size() - 1]
	if rpm >= float(last[0]):
		return float(last[1])
	for i in range(curve.size() - 1):
		var a: Array = curve[i]
		var b: Array = curve[i + 1]
		var r0: float = float(a[0])
		var r1: float = float(b[0])
		if r0 <= rpm and rpm <= r1:
			return lerpf(float(a[1]), float(b[1]), (rpm - r0) / maxf(r1 - r0, 0.001))
	return float(last[1])
