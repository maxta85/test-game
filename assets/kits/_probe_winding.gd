extends SceneTree

# Two quads in the XY plane, identical stored normal (+Z, toward the camera),
# differing ONLY in triangle winding. Camera at +Z. Whatever draws is the
# convention. The background is black, so "did not draw" reads as luma 0.

func _initialize() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(400, 200)
	vp.transparent_bg = false
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	we.environment = env
	vp.add_child(we)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_BACK

	# P1: winding normal +Z (pointing AT the camera)
	_quad(vp, mat, [
		Vector3(-2, -1, 0), Vector3(0, -1, 0), Vector3(0, 1, 0), Vector3(-2, 1, 0)])
	# P2: winding normal -Z (pointing AWAY from the camera)
	_quad(vp, mat, [
		Vector3(0, -1, 0), Vector3(0, 1, 0), Vector3(2, 1, 0), Vector3(2, -1, 0)])

	var cam := Camera3D.new()
	var asked := Vector3(0, 0, 10)
	cam.look_at_from_position(asked, Vector3.ZERO, Vector3.UP)
	vp.add_child(cam)
	cam.make_current()

	for n in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.save_png("/tmp/kits_build/probe_winding.png")

	var left := 0.0
	var right := 0.0
	var ln := 0
	var rn := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			if x < img.get_width() / 2:
				left += l
				ln += 1
			else:
				right += l
				rn += 1
	print("[Wind] asked pos=%s  got pos=%s  current=%s  fov=%.1f" % [
			str(asked), str(cam.global_position), str(cam.current), cam.fov])
	print("[Wind] P1 winding_normal=+Z (AT camera)     luma=%.4f  n=%d" % [left / float(ln), ln])
	print("[Wind] P2 winding_normal=-Z (AWAY camera)  luma=%.4f  n=%d" % [right / float(rn), rn])
	var verdict := "DRAWS-AT-CAMERA"
	if right > 0.5 and left < 0.05:
		verdict = "DRAWS-AWAY-FROM-CAMERA"
	print("[Wind] VERDICT: a face is drawn when the right-hand-rule winding normal points %s" % verdict)
	quit(0)


func _quad(parent: Node, mat: Material, c: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in [c[0], c[1], c[2], c[0], c[2], c[3]]:
		st.set_normal(Vector3(0, 0, 1))
		st.set_uv(Vector2((p as Vector3).x, (p as Vector3).y))
		st.add_vertex(p)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	parent.add_child(mi)
