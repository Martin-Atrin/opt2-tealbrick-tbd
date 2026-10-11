# Seamless photoreal running-bond brick wall tile for TBD's Agent wall.
# Renders the same geometry/lighting in several brick colourways.
# Usage: Blender -b -P brickwall.py -- <outdir> [samples]
import bpy, math, random, sys, os

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "/tmp/brickwall"
SAMPLES = int(argv[1]) if len(argv) > 1 else 128
os.makedirs(OUT, exist_ok=True)

# Real brick: 215 x 65 x 102.5 mm, 10 mm joints.
BW, BH, BD, J = 0.215, 0.065, 0.1025, 0.010
PITCH, COURSE = BW + J, BH + J
N, R = 8, 8                      # bricks per course in the tile, courses
TW, TH = N * PITCH, R * COURSE   # 1.8 m x 0.6 m
RES_X = 2700
RES_Y = int(RES_X * TH / TW)

scene = bpy.context.scene
for o in list(bpy.data.objects): bpy.data.objects.remove(o, do_unlink=True)

# ---------- render settings ----------
scene.render.engine = "CYCLES"
prefs = bpy.context.preferences.addons["cycles"].preferences
try:
    prefs.compute_device_type = "METAL"; prefs.refresh_devices()
    for d in prefs.devices: d.use = True
    scene.cycles.device = "GPU"
except Exception as e:
    print("GPU unavailable:", e)
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.render.resolution_x, scene.render.resolution_y = RES_X, RES_Y
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "JPEG"
scene.render.image_settings.quality = 90
try:
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
except Exception:
    pass

# ---------- world ----------
world = bpy.data.worlds.new("W"); scene.world = world; world.use_nodes = True
bg = world.node_tree.nodes["Background"]; bg.inputs[0].default_value = (0.78, 0.80, 0.84, 1); bg.inputs[1].default_value = 0.35

# ---------- sun (raking from upper left) ----------
sun_data = bpy.data.lights.new("Sun", "SUN"); sun_data.energy = 3.2; sun_data.angle = math.radians(3.5)
sun = bpy.data.objects.new("Sun", sun_data); scene.collection.objects.link(sun)
sun.rotation_euler = (math.radians(46), math.radians(-30), math.radians(-22))

# ---------- camera ----------
cam_data = bpy.data.cameras.new("Cam"); cam_data.type = "ORTHO"; cam_data.ortho_scale = TW; cam_data.sensor_fit = "HORIZONTAL"
cam = bpy.data.objects.new("Cam", cam_data); scene.collection.objects.link(cam)
cam.location = (TW / 2, TH / 2, 3.0); cam.rotation_euler = (0, 0, 0); scene.camera = cam

def node(tree, kind, loc, **kw):
    n = tree.nodes.new(kind); n.location = loc
    for k, v in kw.items(): setattr(n, k, v)
    return n

# ---------- mortar ----------
mortar_mat = bpy.data.materials.new("Mortar"); mortar_mat.use_nodes = True
t = mortar_mat.node_tree; p = t.nodes["Principled BSDF"]
tex = node(t, "ShaderNodeTexCoord", (-900, 0))
nz = node(t, "ShaderNodeTexNoise", (-700, 0)); nz.inputs["Scale"].default_value = 220; nz.inputs["Detail"].default_value = 12
t.links.new(tex.outputs["Object"], nz.inputs["Vector"])
ramp = node(t, "ShaderNodeValToRGB", (-450, 150))
ramp.color_ramp.elements[0].color = (0.42, 0.40, 0.36, 1); ramp.color_ramp.elements[1].color = (0.62, 0.59, 0.53, 1)
t.links.new(nz.outputs["Fac"], ramp.inputs["Fac"]); t.links.new(ramp.outputs["Color"], p.inputs["Base Color"])
p.inputs["Roughness"].default_value = 0.97
bump = node(t, "ShaderNodeBump", (-250, -200)); bump.inputs["Strength"].default_value = 0.9; bump.inputs["Distance"].default_value = 0.002
t.links.new(nz.outputs["Fac"], bump.inputs["Height"]); t.links.new(bump.outputs["Normal"], p.inputs["Normal"])
bpy.ops.mesh.primitive_plane_add(size=1, location=(TW / 2, TH / 2, BD - 0.010))
mortar = bpy.context.object; mortar.scale = (TW * 3, TH * 3, 1); mortar.data.materials.append(mortar_mat)

# ---------- brick material (colourway set by swapping the ramp) ----------
brick_mat = bpy.data.materials.new("Brick"); brick_mat.use_nodes = True
t = brick_mat.node_tree; p = t.nodes["Principled BSDF"]
tex = node(t, "ShaderNodeTexCoord", (-1400, 0))
seed = node(t, "ShaderNodeAttribute", (-1400, -300), attribute_type="OBJECT", attribute_name="seed")
tone = node(t, "ShaderNodeAttribute", (-1400, -450), attribute_type="OBJECT", attribute_name="tone")
metric = node(t, "ShaderNodeVectorMath", (-1250, 0), operation="MULTIPLY"); metric.inputs[1].default_value = (BW, BH, BD)
t.links.new(tex.outputs["Object"], metric.inputs[0])
offset = node(t, "ShaderNodeVectorMath", (-1150, -100), operation="ADD")
t.links.new(metric.outputs["Vector"], offset.inputs[0]); t.links.new(seed.outputs["Vector"], offset.inputs[1])
# clay mottling
nz = node(t, "ShaderNodeTexNoise", (-900, 150)); nz.inputs["Scale"].default_value = 22; nz.inputs["Detail"].default_value = 10; nz.inputs["Roughness"].default_value = 0.68
t.links.new(offset.outputs["Vector"], nz.inputs["Vector"])
ramp = node(t, "ShaderNodeValToRGB", (-650, 250)); ramp.name = "Colourway"
t.links.new(nz.outputs["Fac"], ramp.inputs["Fac"])
# per-brick tone
tone_mul = node(t, "ShaderNodeMix", (-380, 250), data_type="RGBA", blend_type="MULTIPLY"); tone_mul.inputs["Factor"].default_value = 1.0
t.links.new(ramp.outputs["Color"], tone_mul.inputs[6]); t.links.new(tone.outputs["Color"], tone_mul.inputs[7])
# fine speckle / grit
grit = node(t, "ShaderNodeTexNoise", (-900, -150)); grit.inputs["Scale"].default_value = 900; grit.inputs["Detail"].default_value = 4
t.links.new(offset.outputs["Vector"], grit.inputs["Vector"])
gritramp = node(t, "ShaderNodeValToRGB", (-650, -100))
gritramp.color_ramp.elements[0].position = 0.55; gritramp.color_ramp.elements[0].color = (1, 1, 1, 1)
gritramp.color_ramp.elements[1].position = 0.75; gritramp.color_ramp.elements[1].color = (0.55, 0.55, 0.55, 1)
t.links.new(grit.outputs["Fac"], gritramp.inputs["Fac"])
speck = node(t, "ShaderNodeMix", (-150, 150), data_type="RGBA", blend_type="MULTIPLY"); speck.inputs["Factor"].default_value = 1.0
t.links.new(tone_mul.outputs[2], speck.inputs[6]); t.links.new(gritramp.outputs["Color"], speck.inputs[7])
t.links.new(speck.outputs[2], p.inputs["Base Color"])
p.inputs["Roughness"].default_value = 0.88
# surface relief: pits (voronoi) + grain (noise)
vor = node(t, "ShaderNodeTexVoronoi", (-900, -400)); vor.inputs["Scale"].default_value = 160; vor.feature = "DISTANCE_TO_EDGE" if False else "F1"
t.links.new(offset.outputs["Vector"], vor.inputs["Vector"])
pits = node(t, "ShaderNodeMath", (-650, -400), operation="POWER"); pits.inputs[1].default_value = 0.35
t.links.new(vor.outputs["Distance"], pits.inputs[0])
relief = node(t, "ShaderNodeMath", (-450, -400), operation="MULTIPLY_ADD"); relief.inputs[1].default_value = 0.6
t.links.new(pits.outputs[0], relief.inputs[0]); t.links.new(grit.outputs["Fac"], relief.inputs[2])
bump = node(t, "ShaderNodeBump", (-200, -350)); bump.inputs["Strength"].default_value = 0.75; bump.inputs["Distance"].default_value = 0.0014
t.links.new(relief.outputs[0], bump.inputs["Height"]); t.links.new(bump.outputs["Normal"], p.inputs["Normal"])

COLOURWAYS = {
    "red":      [(0.00, (0.30, 0.085, 0.050)), (0.45, (0.47, 0.155, 0.090)), (1.00, (0.60, 0.260, 0.150))],
    "teal":     [(0.00, (0.035, 0.200, 0.185)), (0.45, (0.070, 0.330, 0.300)), (1.00, (0.140, 0.450, 0.410))],
    "tealdeep": [(0.00, (0.012, 0.100, 0.095)), (0.45, (0.030, 0.185, 0.170)), (1.00, (0.070, 0.270, 0.250))],
    "amber":    [(0.00, (0.420, 0.230, 0.050)), (0.45, (0.620, 0.380, 0.090)), (1.00, (0.760, 0.520, 0.170))],
}

def set_colourway(name):
    cr = brick_mat.node_tree.nodes["Colourway"].color_ramp
    stops = COLOURWAYS[name]
    while len(cr.elements) < len(stops): cr.elements.new(0.5)
    for el, (pos, rgb) in zip(cr.elements, stops):
        el.position = pos; el.color = (*rgb, 1)

# ---------- bricks (variation periodic in N so the tile wraps seamlessly) ----------
bpy.ops.mesh.primitive_cube_add(size=1)
proto = bpy.context.object; proto.name = "proto"
bev = proto.modifiers.new("Bevel", "BEVEL"); bev.width = 0.0045; bev.segments = 4; bev.limit_method = "NONE"
proto.data.materials.append(brick_mat)
bpy.ops.object.modifier_apply(modifier="Bevel")
bpy.ops.object.shade_smooth()
mesh = proto.data

for row in range(R):
    offset_x = PITCH / 2 if row % 2 else 0.0
    for k in range(-2, N + 2):
        kp = k % N
        rnd = random.Random(kp * 1009 + row * 9176)
        cx = k * PITCH + offset_x + PITCH / 2
        if cx < -PITCH or cx > TW + PITCH: continue
        o = bpy.data.objects.new(f"b{row}_{k}", mesh); scene.collection.objects.link(o)
        o.location = (cx, row * COURSE + COURSE / 2, BD / 2 - 0.004 + rnd.uniform(-0.0018, 0.0018))
        o.scale = (BW + rnd.uniform(-0.002, 0.0015), BH + rnd.uniform(-0.0015, 0.001), BD)
        o.rotation_euler = (math.radians(rnd.uniform(-0.5, 0.5)), math.radians(rnd.uniform(-0.6, 0.6)), math.radians(rnd.uniform(-0.35, 0.35)))
        o["seed"] = (rnd.uniform(0, 50), rnd.uniform(0, 50), rnd.uniform(0, 50))
        v = rnd.uniform(0.74, 1.12) * (0.62 if rnd.random() < 0.09 else 1.0)
        o["tone"] = (v, v * rnd.uniform(0.93, 1.03), v * rnd.uniform(0.90, 1.02))
bpy.data.objects.remove(proto, do_unlink=True)

for name in (argv[2].split(",") if len(argv) > 2 else COLOURWAYS.keys()):
    set_colourway(name)
    scene.render.filepath = os.path.join(OUT, f"wall-{name}.jpg")
    bpy.ops.render.render(write_still=True)
    print("rendered", scene.render.filepath)

# Layout facts the app needs to place bricks.
with open(os.path.join(OUT, "wall-layout.json"), "w") as f:
    f.write('{"bricksPerCourse": %d, "courses": %d, "pitch": %.4f, "course": %.4f, "brickWidth": %.4f, "brickHeight": %.4f, "tileWidth": %.4f, "tileHeight": %.4f, "pixelsX": %d, "pixelsY": %d}\n' % (N, R, PITCH, COURSE, BW, BH, TW, TH, RES_X, RES_Y))
