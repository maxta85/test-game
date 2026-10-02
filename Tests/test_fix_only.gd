extends RefCounted
## Regression guard for the exposure fix. Run with `./test.sh fix` (--fix-only).
##
## The blowout was never in the grade. Measured on an RTX 3060 over `carhero`,
## a white car lost 35.99% of its bodywork to pure white with almost no local
## contrast left in it (detail 2.96, and a panel line IS local contrast), and
## every obvious lever made it worse rather than better:
##
##     exposure 1.15 / 0.95  paint clip recovered, but the sky fell 36.5 -> 24.6
##                            and the wet road 1.99 -> 1.19. Flattening.
##     filmic 1.00          paint 6.63% but sky 50.2. A night sky brighter than
##     reinhardt 0.80       its own streetlights is not a night scene.
##
## The cause was a car-local `HeroFill` omni 4.2 m directly overhead, which is
## the worst possible place to light a car: maximum NdotL on the horizontal roof
## and boot panels, minimum on the rear-facing panels the player actually looks
## at. Its own comment already admitted it "blows the roof out to a white slab".
##
## So these assertions pin the configuration that produced the measured numbers
## rather than the numbers themselves. A test cannot render a GPU frame, and a
## test that asserted a pixel value would be asserting against whatever machine
## ran it - which is how a real fix gets reverted by someone tidying a constant.

const EXPOSURE := 1.45
const PAINT_CLIP_TARGET := 35.99    # before the fix, from ce-1.45.png
const DETAIL_TARGET := 2.96         # before the fix
const SKY_TARGET := 36.5            # must not collapse: the sky was already right
const ROAD_TARGET := 1.99           # likewise for the wet road
# Above this height an omni sits over the roof and tops it out instead of
# raking the back of the car. 4.2 was the old value and it is the regression.
const MAX_FILL_HEIGHT := 3.2


func run(t: TestHarness) -> void:
	# Both NightEnv and CarVisual assemble themselves in _ready, and adding a node
	# to the tree does not run _ready until the frame is processed. Without this
	# the environment is null and the light rig is still empty.
	await t.ticks(2)
	_grade(t)
	_hero_fill(t)
	_contrast_floor(t)
	_street_frames_the_car(t)
	_note(t)


## The grade must stay where the sweep left it. These two are the numbers that
## cost the scene its sky and road when they moved, so they are pinned hard
## rather than merely checked for being sane.
func _grade(t: TestHarness) -> void:
	var night := NightEnv.new()
	t.new_root("FixOnlyGrade").add_child(night)
	var env: Environment = night.environment

	t.eq(int(env.tonemap_mode), int(Environment.TONE_MAPPER_ACES),
		"tonemap stays ACES: filmic/reinhardt lift the sky to 50-55 and stop the scene reading as night")
	t.near(env.tonemap_exposure, EXPOSURE, 0.001,
		"exposure stays 1.45: 1.15 and 0.95 recover paint but flatten sky and road")


## The actual fix. Asserted structurally, because the thing that matters is not
## "y is some number" but "the fill is not overhead" - which is what broke it.
func _hero_fill(t: TestHarness) -> void:
	# build() is explicit, not _ready(): CarVisual assembles only when the owner
	# asks, so setting `spec` and adding it to the tree builds nothing.
	var visual := CarVisual.new()
	visual.build(CarDB.get_spec("kairo_s13"))
	t.new_root("FixOnlyCar").add_child(visual)

	var fill: OmniLight3D = visual.find_child("HeroFill", true, false) as OmniLight3D
	if not t.ok(fill != null, "the car still has its HeroFill light"):
		return

	t.ok(fill.position.y < MAX_FILL_HEIGHT,
		"HeroFill is not overhead (y=%.1f): above ~%.1f it lights the roof and boot "
		% [fill.position.y, MAX_FILL_HEIGHT]
		+ "square-on and the horizontal panels clip to white")
	t.gt(fill.position.z, 0.0,
		"HeroFill rakes from behind: at z<=0 it sits ahead of the car and stops "
		+ "lighting the rear-facing panels the player looks at")
	# Energy is NOT what fixed it - 1.0 measured 9.79% clip against 1.5's 9.81%,
	# i.e. the same, while costing sky brightness. Pin it so nobody "fixes" it
	# by dimming and quietly flattens the scene again.
	t.near(fill.light_energy, 1.5, 0.001,
		"HeroFill energy stays 1.5: dimming it does not reduce clipping (9.79% vs 9.81%)")


## The earlier lighting fix. Two agents have now been tempted to "improve" a
## contrast value into re-black-clipping the road; this is the tripwire.
func _contrast_floor(t: TestHarness) -> void:
	t.near(Look.ADJUSTMENT_CONTRAST, 1.0, 0.0001,
		"adjustment contrast stays 1.0: above it the bottom of the range clamps "
		+ "to pure black and the unlit road goes back to rgb(0,0,0)")


## The `street` preset showed no car at all while the HUD read POS 1/2, because
## it framed `OSMLayout.start_line()` - 1096 m from where RaceDirector._grid_slot
## actually puts the cars. Anchored on the car, with the map as fallback.
func _street_frames_the_car(t: TestHarness) -> void:
	var offset: Vector3 = ShotPoser.STREET_SHOT[0]
	t.ok(absf(offset.y - 3.2) < 0.01,
		"street preset uses the car-relative framing, not the layout's start line")
	t.ok(ShotPoser.CAR_SHOTS.has("carhero") and ShotPoser.CAR_SHOTS.has("carfront"),
		"car-relative presets are still registered")


## Records the measured before/after so the guard explains itself when it fails,
## and so the numbers have one home that is not a commit message.
func _note(t: TestHarness) -> void:
	t.ok(PAINT_CLIP_TARGET > 0.0 and DETAIL_TARGET > 0.0
			and SKY_TARGET > 0.0 and ROAD_TARGET > 0.0,
		"baseline figures recorded: paint %.2f%%, detail %.2f, sky %.2f, road %.2f"
			% [PAINT_CLIP_TARGET, DETAIL_TARGET, SKY_TARGET, ROAD_TARGET])