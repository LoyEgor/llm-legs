"""blender-render's `logo` scene: an SVG extruded into a studio and rendered as a still, a frame
sequence or a GLB. The spec is one JSON argument after `--`, written by bin/blender-render."""

import json
import sys
import time

import bpy

import kit

spec = json.loads(sys.argv[sys.argv.index("--") + 1])
started = time.time()
scene = kit.clear()
kit.render_settings(scene, size=tuple(spec["size"]), samples=spec["samples"], engine=spec["engine"],
                    transparent=spec["transparent"], view=spec["view"], look=spec["look"], exposure=spec["exposure"],
                    fps=spec["fps"])
logo = kit.import_svg(spec["svg"], width=2.0, depth=spec["depth"], bevel=spec["bevel"])
kit.apply_material(logo, spec["material"], spec["color"])
logo.location.z += spec["float"]

if spec["kind"] == "glb":
    print("RESULT glb=%s" % kit.export_glb(spec["out"], [logo]))
    sys.exit(0)

if spec["backdrop"] not in ("none", "hdri"):
    kit.backdrop(spec["backdrop"])
background = None if spec["backdrop"] == "hdri" else (spec["backdrop"] if spec["backdrop"] != "none" else "#FFFFFF")
kit.world_hdri(scene, spec["hdri"], spec["hdri_strength"], spec["hdri_rotation"], background)
if spec["lights"]:
    _, center = kit.bounds([logo])
    kit.studio_lights(center, key=spec["key"])
kit.camera(scene, [logo], angle=spec["angle"], lens=spec["lens"], margin=spec["margin"], fstop=spec["dof"])

if spec["kind"] == "frames":
    kit.spin(logo, spec["frames"], spec["motion"])
if spec["save"]:
    kit.save_blend(spec["save"])
if spec["kind"] == "frames":
    kit.render_frames(scene, spec["frames_dir"])
    print("RESULT frames=%s" % spec["frames_dir"])
else:
    kit.render_still(scene, spec["out"])
    print("RESULT still=%s" % spec["out"])
print("RESULT seconds=%.1f" % (time.time() - started))
print("RESULT device=%s" % (scene.cycles.device if scene.render.engine == "CYCLES" else "eevee"))
