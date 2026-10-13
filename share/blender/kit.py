"""Scene helpers for headless Blender (bpy), imported by blender-render's scene scripts and by any
script run through `blender-render run`. Units: the subject is normalized to ~2 m wide, lights and
backdrop are sized for that."""

import math
import os

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Vector

ASSETS = os.path.expanduser(os.environ.get("BLENDER_ASSETS", "~/.local/share/blender-assets"))
LOOK = "AgX - Medium High Contrast"
# Neutral keeps a brand color's base color on screen; AgX desaturates bright colors (mint, not green).
VIEWS = {"neutral": "Khronos PBR Neutral", "agx": "AgX", "standard": "Standard"}

ANGLES = {
    "front": (0, 0),
    "hero": (-28, 12),
    "three-quarter": (-40, 18),
    "low": (-22, -4),
    "top": (0, 62),
    "side": (-75, 8),
}

MATERIALS = {
    "gloss": dict(roughness=0.18, coat=1.0, coat_roughness=0.04),
    "matte": dict(roughness=0.62),
    "satin": dict(roughness=0.34, coat=0.4, coat_roughness=0.2),
    "metal": dict(metallic=1.0, roughness=0.24),
    "brushed": dict(metallic=1.0, roughness=0.32, anisotropic=0.85),
    "gold": dict(color="#FFC356", metallic=1.0, roughness=0.16),
    "chrome": dict(color="#F2F2F2", metallic=1.0, roughness=0.04),
    "copper": dict(color="#F4A281", metallic=1.0, roughness=0.2),
    "glass": dict(transmission=1.0, roughness=0.02, ior=1.45),
    "frosted": dict(transmission=1.0, roughness=0.32, ior=1.45),
    "clay": dict(color="#D9D6D0", roughness=0.85),
    "emissive": dict(roughness=0.4, emission=6.0),
}


def linear(hex_color):
    value = hex_color.lstrip("#")
    channels = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels) + (1.0,)


def clear():
    for collection in (bpy.data.objects, bpy.data.meshes, bpy.data.curves, bpy.data.materials,
                       bpy.data.lights, bpy.data.cameras, bpy.data.worlds, bpy.data.images):
        for block in list(collection):
            collection.remove(block)
    scene = bpy.context.scene
    scene.world = bpy.data.worlds.new("World")
    return scene


def gpu(scene):
    """Cycles on every Metal device; CPU when there is none."""
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    used = []
    for device in prefs.devices:
        device.use = device.type == "METAL"
        if device.use:
            used.append(device.name)
    scene.cycles.device = "GPU" if used else "CPU"
    return used


def render_settings(scene, size=(1920, 1080), samples=256, engine="cycles", transparent=False,
                    view="neutral", look=None, exposure=0.0, fps=30):
    render = scene.render
    render.resolution_x, render.resolution_y = size
    render.resolution_percentage = 100
    render.film_transparent = transparent
    render.fps = fps
    render.use_persistent_data = True
    if engine == "eevee":
        render.engine = "BLENDER_EEVEE"
        scene.eevee.taa_render_samples = max(samples, 64)
        scene.eevee.use_raytracing = True
    else:
        render.engine = "CYCLES"
        gpu(scene)
        cycles = scene.cycles
        cycles.samples = samples
        cycles.adaptive_threshold = 0.006
        cycles.use_denoising = True
        cycles.denoiser = "OPENIMAGEDENOISE"
        cycles.denoising_use_gpu = True
        cycles.max_bounces = 16
        cycles.glossy_bounces = 8
        cycles.transmission_bounces = 16
        cycles.transparent_max_bounces = 16
        cycles.caustics_reflective = False
        cycles.caustics_refractive = False
        cycles.blur_glossy = 0.5
    settings = scene.view_settings
    settings.view_transform = VIEWS[view]
    settings.look = (look or LOOK) if view == "agx" else "None"
    settings.exposure = exposure
    image = render.image_settings
    image.file_format = "PNG"
    image.color_mode = "RGBA" if transparent else "RGB"
    image.color_depth = "16"
    image.compression = 15


def material(name, preset="gloss", color="#169148"):
    spec = dict(MATERIALS[preset])
    tint = linear(spec.pop("color", color))
    mat = bpy.data.materials.new(name)
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    inputs = bsdf.inputs
    inputs["Base Color"].default_value = tint
    inputs["Metallic"].default_value = spec.get("metallic", 0.0)
    inputs["Roughness"].default_value = spec.get("roughness", 0.4)
    inputs["IOR"].default_value = spec.get("ior", 1.5)
    inputs["Coat Weight"].default_value = spec.get("coat", 0.0)
    inputs["Coat Roughness"].default_value = spec.get("coat_roughness", 0.03)
    inputs["Anisotropic"].default_value = spec.get("anisotropic", 0.0)
    inputs["Transmission Weight"].default_value = spec.get("transmission", 0.0)
    if spec.get("emission"):
        inputs["Emission Color"].default_value = tint
        inputs["Emission Strength"].default_value = spec["emission"]
    mat.diffuse_color = tint
    return mat


def world_hdri(scene, name="studio_small_09", strength=1.0, rotation=0.0, background=None):
    """HDRI lighting and reflections; `background` (hex) is what the camera sees instead of the
    HDRI, None shows the HDRI itself. A transparent film hides either."""
    path = hdri_path(name)
    world = scene.world
    nodes, links = world.node_tree.nodes, world.node_tree.links
    nodes.clear()
    coords = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    mapping.inputs["Rotation"].default_value[2] = math.radians(rotation)
    texture = nodes.new("ShaderNodeTexEnvironment")
    texture.image = bpy.data.images.load(path, check_existing=True)
    light = nodes.new("ShaderNodeBackground")
    light.inputs["Strength"].default_value = strength
    output = nodes.new("ShaderNodeOutputWorld")
    links.new(coords.outputs["Generated"], mapping.inputs["Vector"])
    links.new(mapping.outputs["Vector"], texture.inputs["Vector"])
    links.new(texture.outputs["Color"], light.inputs["Color"])
    if background is None:
        links.new(light.outputs["Background"], output.inputs["Surface"])
        return
    seen = nodes.new("ShaderNodeBackground")
    seen.inputs["Color"].default_value = linear(background)
    path_node = nodes.new("ShaderNodeLightPath")
    mix = nodes.new("ShaderNodeMixShader")
    links.new(path_node.outputs["Is Camera Ray"], mix.inputs["Fac"])
    links.new(light.outputs["Background"], mix.inputs[1])
    links.new(seen.outputs["Background"], mix.inputs[2])
    links.new(mix.outputs["Shader"], output.inputs["Surface"])


def world_color(scene, hex_color="#FFFFFF", strength=0.6):
    nodes = scene.world.node_tree.nodes
    background = nodes.get("Background") or nodes.new("ShaderNodeBackground")
    background.inputs["Color"].default_value = linear(hex_color)
    background.inputs["Strength"].default_value = strength


def hdri_path(name):
    if os.path.isfile(name):
        return name
    folder = os.path.join(ASSETS, "hdri")
    found = sorted(f for f in os.listdir(folder) if f.startswith(name + "_")) if os.path.isdir(folder) else []
    if not found:
        raise SystemExit("no HDRI %r in %s — blender-render assets fetch %s" % (name, folder, name))
    return os.path.join(folder, found[-1])


def backdrop(color="#F2F0EA", width=40.0, depth=18.0, height=14.0, radius=4.0, roughness=0.55, z=0.0):
    """A seamless studio sweep: floor toward the camera (-Y), curving up into a wall behind."""
    profile = [(-depth, z)]
    steps = 24
    for i in range(steps + 1):
        angle = math.pi / 2 * i / steps
        profile.append((radius * math.sin(angle), z + radius * (1 - math.cos(angle))))
    profile.append((radius, z + height))
    verts, faces = [], []
    for x in (-width / 2, width / 2):
        verts.extend((x, y, zz) for y, zz in profile)
    count = len(profile)
    faces = [(i, i + 1, count + i + 1, count + i) for i in range(count - 1)]
    mesh = bpy.data.meshes.new("Backdrop")
    mesh.from_pydata(verts, [], faces)
    for poly in mesh.polygons:
        poly.use_smooth = True
    obj = bpy.data.objects.new("Backdrop", mesh)
    bpy.context.scene.collection.objects.link(obj)
    mat = bpy.data.materials.new("Backdrop")
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = linear(color)
    bsdf.inputs["Roughness"].default_value = roughness
    obj.data.materials.append(mat)
    return obj


def area_light(name, location, target, power, size, color="#FFFFFF"):
    light = bpy.data.lights.new(name, "AREA")
    light.energy = power
    light.size = size
    light.color = linear(color)[:3]
    obj = bpy.data.objects.new(name, light)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = location
    aim(obj, target)
    return obj


def studio_lights(center, scale=1.0, key=900.0):
    """Key (upper left), fill (right), rim (behind, above) — soft product lighting."""
    c = Vector(center)
    return [
        area_light("Key", c + Vector((-3.2, -3.4, 3.6)) * scale, c, key * scale ** 2, 3.0 * scale),
        area_light("Fill", c + Vector((4.2, -2.6, 1.2)) * scale, c, key * 0.28 * scale ** 2, 4.0 * scale),
        area_light("Rim", c + Vector((0.8, 3.2, 3.4)) * scale, c, key * 0.7 * scale ** 2, 2.0 * scale),
    ]


def aim(obj, target):
    direction = Vector(target) - obj.location
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def import_svg(path, width=2.0, depth=0.12, bevel=0.01, upright=True):
    """The SVG as one solid mesh, `width` m wide, `depth` thick, standing on z=0 facing -Y.
    Fill colors from the file stay as one material slot per color."""
    before = set(bpy.data.objects)
    bpy.ops.import_curve.svg(filepath=path)
    curves = [obj for obj in bpy.data.objects if obj not in before and obj.type == "CURVE"]
    if not curves:
        raise SystemExit("no curves imported from %s" % path)
    for obj in bpy.data.objects:
        obj.select_set(obj in curves)
    bpy.context.view_layer.objects.active = curves[0]
    if len(curves) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    # transform_apply leaves a curve's scale on its extrude and bevel, so the points are rescaled
    # in place and the object keeps an identity transform.
    obj.data.transform(obj.matrix_world)
    obj.matrix_world = Matrix.Identity(4)
    corners = [Vector(corner) for corner in obj.bound_box]
    low = Vector((min(c.x for c in corners), min(c.y for c in corners), 0))
    high = Vector((max(c.x for c in corners), max(c.y for c in corners), 0))
    factor = width / max(high.x - low.x, 1e-9)
    obj.data.transform(Matrix.Scale(factor, 4) @ Matrix.Translation(-(low + high) / 2))
    data = obj.data
    # Curve.transform scales every point radius too, and a 2D curve's extrude follows the radius.
    for spline in data.splines:
        for point in list(spline.bezier_points) + list(spline.points):
            point.radius = 1.0
    data.dimensions = "2D"
    data.fill_mode = "BOTH"
    data.resolution_u = 32
    data.extrude = depth / 2
    data.bevel_depth = bevel
    data.bevel_resolution = 6
    bpy.ops.object.convert(target="MESH")
    obj = bpy.context.view_layer.objects.active
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(35))
    if upright:
        obj.data.transform(Matrix.Rotation(math.radians(90), 4, "X"))
    lowest = min(v.co.z for v in obj.data.vertices)
    obj.data.transform(Matrix.Translation((0, 0, -lowest)))
    obj.name = os.path.splitext(os.path.basename(path))[0]
    for collection in list(bpy.data.collections):
        if not collection.objects:
            bpy.data.collections.remove(collection)
    return obj


def apply_material(obj, preset, color=None):
    """One preset over every slot; with color None each slot keeps its SVG fill color."""
    slots = obj.material_slots
    if not slots:
        obj.data.materials.append(material(obj.name, preset, color or "#169148"))
        return
    for index, slot in enumerate(slots):
        fill = color or rgb_hex(svg_fill(slot.material))
        slot.material = material("%s.%d" % (obj.name, index), preset, fill)


def svg_fill(mat):
    """The importer's fill color (its Diffuse node), black when it could not read one — class-based
    CSS fills come out black, which is why blender-render passes a single fill as --color."""
    if mat and mat.node_tree:
        for node in mat.node_tree.nodes:
            for name in ("Color", "Base Color"):
                if node.type in ("BSDF_DIFFUSE", "BSDF_PRINCIPLED") and name in node.inputs:
                    return node.inputs[name].default_value
    return mat.diffuse_color if mat else (0, 0, 0, 1)


def rgb_hex(linear_rgba):
    def to_srgb(c):
        return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
    return "#" + "".join("%02X" % round(max(0, min(1, to_srgb(c))) * 255) for c in linear_rgba[:3])


def bounds(objects):
    # bound_box stays stale after a mesh data.transform until the depsgraph updates.
    bpy.context.view_layer.update()
    corners = [obj.matrix_world @ Vector(corner) for obj in objects for corner in obj.bound_box]
    low = Vector((min(c.x for c in corners), min(c.y for c in corners), min(c.z for c in corners)))
    high = Vector((max(c.x for c in corners), max(c.y for c in corners), max(c.z for c in corners)))
    return corners, (low + high) / 2


def camera(scene, objects, angle="hero", lens=70.0, margin=1.25, fstop=None):
    """A camera at `angle` (name from ANGLES or (azimuth, elevation) degrees) that fits `objects`
    with `margin` of air, measured on the projected bounding box."""
    azimuth, elevation = ANGLES[angle] if isinstance(angle, str) else angle
    corners, center = bounds(objects)
    data = bpy.data.cameras.new("Camera")
    data.lens = lens
    cam = bpy.data.objects.new("Camera", data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    a, e = math.radians(azimuth), math.radians(elevation)
    direction = Vector((math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e)))
    distance = 10.0
    for _ in range(4):
        cam.location = center + direction * distance
        aim(cam, center)
        bpy.context.view_layer.update()
        projected = [world_to_camera_view(scene, cam, corner) for corner in corners]
        extent = max(max(abs(p.x - 0.5), abs(p.y - 0.5)) for p in projected) * 2
        distance *= extent * margin
    cam.location = center + direction * distance
    aim(cam, center)
    if fstop:
        data.dof.use_dof = True
        data.dof.focus_distance = distance
        data.dof.aperture_fstop = fstop
    return cam


def spin(obj, frames, motion="turntable", amplitude=28.0):
    """Seamless loop over `frames`: a full turn, or a swing of ±amplitude degrees."""
    curve = obj.driver_add("rotation_euler", 2)
    if motion == "turntable":
        curve.driver.expression = "2*pi*frame/%d" % frames
    else:
        curve.driver.expression = "radians(%g)*sin(2*pi*frame/%d)" % (amplitude, frames)
    scene = bpy.context.scene
    scene.frame_start, scene.frame_end = 0, frames - 1


def render_still(scene, path):
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def render_frames(scene, folder):
    os.makedirs(folder, exist_ok=True)
    scene.render.filepath = os.path.join(folder, "f_")
    bpy.ops.render.render(animation=True)
    return folder


def export_glb(path, objects):
    for obj in bpy.data.objects:
        obj.select_set(obj in objects)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True,
                              export_apply=True, export_draco_mesh_compression_enable=True,
                              export_draco_mesh_compression_level=6, export_yup=True)
    return path


def save_blend(path):
    bpy.ops.wm.save_as_mainfile(filepath=path, compress=True)
    return path
