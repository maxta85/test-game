# Decision: an Art Director role owns a shared art vocabulary

Date: 2026-09-30
Status: accepted, in progress (`agent/art`)

## Context

The world is built from 24 primitive-construction call sites: 131 generated
houses, 1621 palms, 1234 bushes, 1278 streetlights, all with flat single-colour
materials. Rendered, it reads as orange polygons in darkness.

Every agent left to its own devices produces more of the same thing, and they
will produce it *inconsistently* — five agents each inventing a palm. The
problem is not that any one agent is bad at geometry. It is that there is no
shared vocabulary for them to be consistent with, and no standard to be held to.

## Decision

Add a first-class **Art Director / Asset Pipeline** role, owning one path
exclusively: `artkit/`.

- Every other agent **consumes** `artkit/` and **never edits** it.
- It ships a palette, a material library with real variation, generators for
  props and buildings, and a written `standards.md` covering triangle budgets,
  draw calls, LOD and scale.
- One path, one owner. This is specifically to avoid a shared library becoming
  the merge conflict that already broke `main` once.

## The constraint that shapes it

**No agent here can model or paint.** They write GDScript. The only real binary
assets in the repo are seven car `.glb` files someone downloaded, which is not a
reproducible pipeline.

So "assets" in this project means *a reusable library of generator functions
and shared materials*, not modelled files. The brief says this to the agent
explicitly so it does not ship something hollow, and the self-check compares
material albedo values precisely because a library of N identical materials
looks like a library and behaves like a bug.

This is a smaller claim than "30 excellent assets" and it is the one that is
true here. It is still worth far more than 3000 primitives.

## The gate

`checks/beauty_check.sh` renders one stretch of the map at night and routes it
through a vision model with a seven-point rubric — asphalt, markings, buildings,
vegetation, lighting, atmosphere, material variation — asked to be harsh.

It does **not** auto-pass. An automated art judgement is a prompt for human
judgement, not a substitute for it. The lead reads it and decides.

**No agent is authorised to expand the world until the beauty shot is
acceptable.** This is the specific guard against spending ten hours generating a
large bad map: the map agent must make one good 500 m stretch first.

## Why not just tell agents to "make it prettier"

Because "prettier" is not actionable and every agent will interpret it
differently. A shared library plus written budgets converts taste into an
interface. That is the whole point of the role.
