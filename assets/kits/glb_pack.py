#!/usr/bin/env python3
"""Pack the house kit's measured JSON into glTF 2.0 binary (.glb).

Why this exists: Godot 4.3's GLTFDocument has append_from_scene but NOT
save_to_file (probed with ClassDB.class_has_method; calling it raises
"Nonexistent function 'save_to_file' in base 'GLTFDocument'"). save_to_file
landed in 4.4. So the binaries are written here instead, from the arrays that
assets/kits/house_kit_export.gd measured.

Structure per file, deliberately minimal and deliberately one node:

    <12-byte header>
      magic 'glTF' | version 2 | total length
    <JSON chunk>  0x4E4F534A  'JSON', space-padded to 4 bytes
    <BIN chunk>   0x004E4942  'BIN\\0', zero-padded to 4 bytes

The scene has exactly ONE node and it is named after the kit piece, which is
also the file stem. One node, one origin, one fastening point. The extras block
carries the archetype, the origin rule in words, the silhouette claim and the
measured triangle count, so a consumer can read the contract off the file
without this repository.

Usage:
    python3 assets/kits/glb_pack.py /tmp/kits_build assets/kits
"""

from __future__ import annotations

import json
import os
import struct
import sys

FLOAT = 5126
UINT32 = 5125
ARRAY_BUFFER = 34962
ELEMENT_ARRAY_BUFFER = 34963


def _pad(n: int, mult: int = 4) -> int:
    return (mult - (n % mult)) % mult


class Buf:
    """One binary buffer, with 4-byte aligned appends."""

    def __init__(self) -> None:
        self.data = bytearray()
        self.views: list[dict] = []

    def add(self, payload: bytes, target: int) -> int:
        while len(self.data) % 4:
            self.data.append(0)
        offset = len(self.data)
        self.data += payload
        self.views.append(
            {"buffer": 0, "byteOffset": offset, "byteLength": len(payload), "target": target}
        )
        return len(self.views) - 1


def _floats(values: list[float]) -> bytes:
    return struct.pack("<%df" % len(values), *values)


def pack(doc: dict) -> bytes:
    name = doc["name"]
    extras = doc["extras"]
    buf = Buf()
    accessors: list[dict] = []
    materials: list[dict] = []
    primitives: list[dict] = []

    for role, entry in doc["roles"].items():
        payload = entry["payload"]
        pos = [round(float(v), 6) for v in payload["position"]]
        nrm = [round(float(v), 6) for v in payload["normal"]]
        uvs = [round(float(v), 6) for v in payload["uv"]]
        ind = [int(v) for v in payload["index"]]
        if not pos:
            continue
        n_vert = len(pos) // 3
        if len(ind) % 3:
            raise SystemExit(f"{name}/{role}: index count {len(ind)} is not a multiple of 3")

        lo = [min(pos[i::3]) for i in range(3)]
        hi = [max(pos[i::3]) for i in range(3)]

        # POSITION. min/max are REQUIRED by the glTF spec on this accessor.
        a_pos = len(accessors)
        buf.add(_floats(pos), ARRAY_BUFFER)
        accessors.append(
            {
                "bufferView": len(buf.views) - 1,
                "componentType": FLOAT,
                "count": n_vert,
                "type": "VEC3",
                "min": lo,
                "max": hi,
            }
        )
        a_nrm = len(accessors)
        buf.add(_floats(nrm), ARRAY_BUFFER)
        accessors.append(
            {
                "bufferView": len(buf.views) - 1,
                "componentType": FLOAT,
                "count": n_vert,
                "type": "VEC3",
            }
        )
        a_uv = len(accessors)
        buf.add(_floats(uvs), ARRAY_BUFFER)
        accessors.append(
            {
                "bufferView": len(buf.views) - 1,
                "componentType": FLOAT,
                "count": n_vert,
                "type": "VEC2",
            }
        )
        # Indices are 32-bit: a piece must not be at the mercy of a 65k limit
        # for no benefit, and the alignment cost is 2 bytes per triangle.
        a_idx = len(accessors)
        buf.add(struct.pack("<%dI" % len(ind), *ind), ELEMENT_ARRAY_BUFFER)
        accessors.append(
            {
                "bufferView": len(buf.views) - 1,
                "componentType": UINT32,
                "count": len(ind),
                "type": "SCALAR",
            }
        )

        spec = entry["material"]
        materials.append(
            {
                "name": role,
                "doubleSided": False,
                "pbrMetallicRoughness": {
                    "baseColorFactor": [round(float(c), 6) for c in spec["color"]],
                    "metallicFactor": round(float(spec["metallic"]), 6),
                    "roughnessFactor": round(float(spec["roughness"]), 6),
                },
            }
        )
        primitives.append(
            {
                "attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv},
                "indices": a_idx,
                "material": len(materials) - 1,
                "extras": {"role": role},
            }
        )

    if not primitives:
        raise SystemExit(f"{name}: no primitives")

    gltf = {
        "asset": {
            "version": "2.0",
            "generator": "cairns-after-dark house kit / assets/kits/glb_pack.py",
            "copyright": "Cairns After Dark - procedural, no downloaded art",
        },
        "scene": 0,
        "scenes": [{"name": name, "nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0, "extras": extras}],
        "meshes": [{"name": name + "_mesh", "primitives": primitives}],
        "materials": materials,
        "accessors": accessors,
        "bufferViews": buf.views,
        "buffers": [{"byteLength": len(buf.data)}],
    }

    json_bytes = json.dumps(gltf, separators=(",", ":"), sort_keys=True).encode("utf-8")
    json_bytes += b" " * _pad(len(json_bytes))
    bin_bytes = bytes(buf.data) + b"\x00" * _pad(len(buf.data))

    total = 12 + 8 + len(json_bytes) + 8 + len(bin_bytes)
    out = bytearray()
    out += b"glTF" + struct.pack("<II", 2, total)
    out += struct.pack("<I", len(json_bytes)) + b"JSON" + json_bytes
    out += struct.pack("<I", len(bin_bytes)) + b"BIN\x00" + bin_bytes
    return bytes(out)


def main() -> int:
    src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/kits_build"
    dst = sys.argv[2] if len(sys.argv) > 2 else "assets/kits"
    if not os.path.isdir(src):
        raise SystemExit(f"no such dir: {src}")
    names = sorted(f for f in os.listdir(src) if f.startswith("kit_") and f.endswith(".json"))
    if not names:
        raise SystemExit(f"no kit_*.json in {src} - run house_kit_export.gd first")
    os.makedirs(dst, exist_ok=True)
    for fn in names:
        with open(os.path.join(src, fn), "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        blob = pack(doc)
        out = os.path.join(dst, doc["name"] + ".glb")
        with open(out, "wb") as fh:
            fh.write(blob)
        print(
            "[glb_pack] %-28s %7d bytes  prims=%d  tris=%d"
            % (doc["name"], len(blob), len(doc["roles"]), doc["extras"]["triangles"])
        )
    print(f"[glb_pack] wrote {len(names)} files to {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())