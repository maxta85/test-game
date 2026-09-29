class_name ShotPoser
extends Node3D
## Moves the camera to fixed vantage points so renders can be compared like for
## like between passes. Without this, "it looks better" is unmeasurable because
## every screenshot frames something different.
##
## ./run.sh --shot NAME [PRESET]

const PRESETS := {
	# name: [cam_pos, cam_look_at, fov, hide_car]
	"start":      [Vector3(-30, 6, 58), Vector3(10, 1.2, 40), 55.0, true],
	"street":     [Vector3(0, 3.2, -60), Vector3(0, 1.0, 30), 50.0, true],
	"downtown":   [Vector3(-70, 14, -40), Vector3(10, 2, 60), 60.0, true],
	"kerb":       [Vector3(14, 1.1, 62), Vector3(-6, 0.6, 20), 45.0, true],
	"carmeet":    [Vector3(-60, 8, 100), Vector3(-84, 1.5, 118), 55.0, true],
	"aerial":     [Vector3(0, 420, 340), Vector3(0, 0, 0), 60.0, true],
	"motorway":   [Vector3(0, 12, -420), Vector3(30, 2, -300), 55.0, true],
}


static func apply(node: Node, preset_name: String) -> bool:
	if not PRESETS.has(preset_name):
		return false
	var p: Array = PRESETS[preset_name]
	var cam: Camera3D = null
	for c in node.get_children():
		if c is Camera3D:
			cam = c
	if cam == null:
		return false
	cam.global_position = p[0]
	cam.look_at(Vector3(p[1]), Vector3.UP)
	cam.fov = float(p[2])
	return true
