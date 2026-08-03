"""Fix right-hand finger skinning in assets/mixamo_test.blend.

Problem
-------
The mesh Ch36 carries vertex groups hand.L.001-.014 for the left fingers but has
no hand.R.001-.014 counterparts. The armature does define all 14 right finger
deform bones, and the Armature modifier is in vertex-group mode with bone
envelopes off -- so those bones have nothing to bind to. Every right finger
vertex instead sits in the single hand.R palm group (642 verts, vs 223 for
hand.L), which is why the right hand deforms as one rigid block.

Fix
---
The mesh is a mirrored character, so rebuild the right hand's weights from the
left, swapping .L -> .R in the group names.

Matching the two sides by nearest mirrored position alone is not safe: ~12% of
the left-hand verts have no exact mirror twin (the model carries small
asymmetric jitter, up to ~15mm), and finger-to-finger spacing is only ~20mm, so
a vertex can snap onto the neighbouring finger. Instead we seed the map with the
verts that DO mirror exactly and then propagate it across mesh edges -- a
partner's neighbours are the only candidates for a neighbour's partner. The
result is checked for bijectivity and involution before any weight is written.

Also removes a dead Armature modifier whose object pointer is None.

Reads the source blend and writes a new one; the source is never modified.

  blender.exe -b assets/mixamo_test.blend \
      -P tools/fix_mixamo_right_hand_weights.py -- //assets/mixamo_test_fixed.blend
"""

import sys
import bpy
from mathutils import kdtree, Vector

MESH = "Ch36"
ARMATURE = "Armature"
EXACT = 1e-4    # seed pairs must mirror this precisely
TOL = 0.05      # propagated pairs may drift by at most this (finger pitch ~0.02)

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out_path = argv[0] if argv else "//assets/mixamo_test_fixed.blend"


def swap_side(name):
    """hand.L.003 -> hand.R.003, forearm.L -> forearm.R, others unchanged."""
    if name.endswith(".L") or ".L." in name:
        return name.replace(".L", ".R", 1)
    if name.endswith(".R") or ".R." in name:
        return name.replace(".R", ".L", 1)
    return name


def build_mirror_map(me):
    """Map every vertex to its mirror twin across local x=0, or None."""
    verts = me.vertices
    kd = kdtree.KDTree(len(verts))
    for v in verts:
        kd.insert(v.co, v.index)
    kd.balance()

    def mirrored(i):
        c = verts[i].co
        return Vector((-c.x, c.y, c.z))

    # -- seed: verts whose mirror image lands exactly on another vert --------
    partner = {}
    for v in verts:
        co, idx, d = kd.find(mirrored(v.index))
        if d <= EXACT:
            partner[v.index] = idx
    # keep only mutually-agreeing seeds
    partner = {a: b for a, b in partner.items() if partner.get(b) == a}
    print(f"seed pairs (exact mirror): {len(partner)}/{len(verts)}")

    # -- propagate across edges ---------------------------------------------
    adj = [[] for _ in verts]
    for e in me.edges:
        a, b = e.vertices
        adj[a].append(b)
        adj[b].append(a)

    taken = set(partner.values())
    changed = True
    rounds = 0
    while changed:
        changed = False
        rounds += 1
        for v in verts:
            i = v.index
            if i in partner:
                continue
            target = mirrored(i)
            # candidates: neighbours of the partners of i's matched neighbours
            cands = set()
            for n in adj[i]:
                p = partner.get(n)
                if p is not None:
                    cands.update(adj[p])
                    cands.add(p)
            best, best_d = None, TOL
            for c in cands:
                if c in taken or c == i:
                    continue
                d = (verts[c].co - target).length
                if d < best_d:
                    best, best_d = c, d
            if best is not None:
                # mirroring is an involution -- record both ends, or the
                # partner stays "unmatched" and can be claimed twice
                partner[i] = best
                partner[best] = i
                taken.add(best)
                taken.add(i)
                changed = True
    print(f"after {rounds} propagation rounds: {len(partner)}/{len(verts)} matched")
    return partner


def main():
    ob = bpy.data.objects[MESH]
    arm = bpy.data.objects[ARMATURE]
    me = ob.data

    # --- 1. drop the dead armature modifier -------------------------------
    for m in list(ob.modifiers):
        if m.type == "ARMATURE" and m.object is None:
            print(f"removing dead armature modifier {m.name!r} (object=None)")
            ob.modifiers.remove(m)
    live = [m for m in ob.modifiers if m.type == "ARMATURE"]
    assert len(live) == 1 and live[0].object is arm, f"unexpected modifiers: {live}"
    live[0].use_vertex_groups = True

    # --- 2. mirror map + validation ---------------------------------------
    partner = build_mirror_map(me)

    idx2name = {vg.index: vg.name for vg in ob.vertex_groups}
    left_groups = {vg.index for vg in ob.vertex_groups
                   if vg.name == "hand.L" or vg.name.startswith("hand.L.")}
    assert len(left_groups) == 15, f"expected 15 left-hand groups, got {len(left_groups)}"
    right_palm = ob.vertex_groups["hand.R"].index

    # Drive from the target (right) side: the two hands are not topologically
    # identical -- the right has 7 fewer verts around the fingers -- so a full
    # left->right bijection is impossible, but nearly every right vert does have
    # a left twin.
    targets = [v.index for v in me.vertices
               if any(g.group == right_palm and g.weight > 0.0 for g in v.groups)]
    print(f"right-hand target verts: {len(targets)}")

    mapping = {t: partner[t] for t in targets if t in partner}
    orphans = [t for t in targets if t not in mapping]
    print(f"  matched to a left twin: {len(mapping)}, orphans: {len(orphans)}")

    assert len(set(mapping.values())) == len(mapping), "mirror map is not injective"
    for t, s in mapping.items():
        assert partner.get(s) == t, f"mirror not involutive: {t} -> {s} -> {partner.get(s)}"
        assert me.vertices[s].co.x * me.vertices[t].co.x < 0, f"pair {s}/{t} not across x=0"
        assert any(g.group in left_groups and g.weight > 0.0
                   for g in me.vertices[s].groups), \
            f"twin {s} of right-hand vert {t} carries no left-hand weight"
    worst = max((me.vertices[t].co - Vector((-me.vertices[s].co.x,
                                             me.vertices[s].co.y,
                                             me.vertices[s].co.z))).length
                for t, s in mapping.items())
    print(f"mirror map: {len(mapping)} pairs, injective, involutive, worst dist={worst:.6g}")

    # --- 3. create the missing right-finger groups ------------------------
    for i in range(1, 15):
        name = f"hand.R.{i:03d}"
        if name not in ob.vertex_groups:
            ob.vertex_groups.new(name=name)
    print("created hand.R.001-.014")

    # --- 4. mirror the weights --------------------------------------------
    # Read every source weight up front so no write can perturb a later read.
    plan = {t: {swap_side(idx2name[g.group]): g.weight
                for g in me.vertices[s].groups if g.weight > 0.0}
            for t, s in mapping.items()}

    # Orphans have no left twin; blend the freshly-mirrored weights of their
    # matched mesh neighbours. Local by construction, so it cannot reach across
    # to the wrong finger.
    adj = [[] for _ in me.vertices]
    for e in me.edges:
        a, b = e.vertices
        adj[a].append(b)
        adj[b].append(a)
    for t in orphans:
        acc = {}
        contributors = [n for n in adj[t] if n in plan]
        assert contributors, f"orphan {t} has no matched neighbour to interpolate from"
        for n in contributors:
            for name, w in plan[n].items():
                acc[name] = acc.get(name, 0.0) + w
        total = sum(acc.values())
        plan[t] = {name: w / total for name, w in acc.items()}
        print(f"  orphan {t}: interpolated from {len(contributors)} neighbours "
              f"-> {sorted(plan[t], key=plan[t].get, reverse=True)[:3]}")

    for weights in plan.values():
        for name in weights:
            assert name in ob.vertex_groups, f"no target group {name!r}"
    assert set(plan) == set(targets), "plan does not cover exactly the target set"
    assert not (set(plan) & set(mapping.values())), "source and target sets overlap"

    for t in plan:
        for g in list(me.vertices[t].groups):
            ob.vertex_groups[idx2name[g.group]].remove([t])
    written = 0
    for t, weights in plan.items():
        for name, w in weights.items():
            ob.vertex_groups[name].add([t], w, "REPLACE")
            written += 1
    print(f"rewrote {len(plan)} right-hand verts, {written} weight entries")

    # --- 5. verify ---------------------------------------------------------
    def stats(gname):
        gi = ob.vertex_groups[gname].index
        pts = [v.co for v in me.vertices
               for g in v.groups if g.group == gi and g.weight > 0.0]
        c = sum(pts, Vector()) / len(pts) if pts else None
        return len(pts), c

    print("group                 nL   nR   centroid mirror error")
    for name in ["hand"] + [f"hand.{i:03d}" for i in range(1, 15)]:
        ln = name.replace("hand", "hand.L", 1) if name == "hand" else f"hand.L.{name[5:]}"
        rn = name.replace("hand", "hand.R", 1) if name == "hand" else f"hand.R.{name[5:]}"
        nl, cl = stats(ln)
        nr, cr = stats(rn)
        assert nr > 0, f"{rn} is empty -- its bone would still deform nothing"
        err = (cr - Vector((-cl.x, cl.y, cl.z))).length
        print(f"  {ln:12s} {nl:5d} {nr:4d}   {err:.5f}")
        assert err < 0.02, f"{rn} centroid does not mirror {ln} (err={err:.4g})"

    # every right finger bone must now actually drive geometry
    for b in arm.data.bones:
        if b.use_deform:
            assert b.name in ob.vertex_groups, f"deform bone {b.name!r} has no vertex group"
    print("verified: every deform bone has a vertex group")

    for v in me.vertices:
        assert sum(g.weight for g in v.groups) > 1e-6, f"vert {v.index} left unweighted"
    print("verified: no unweighted vertices")

    bpy.ops.wm.save_as_mainfile(filepath=bpy.path.abspath(out_path))
    print(f"wrote {out_path}")


main()
