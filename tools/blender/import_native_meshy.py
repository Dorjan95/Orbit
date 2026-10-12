"""Import and export the supplied animations unchanged; no authored Orbit gestures.

Run with Blender --background --python. Source timing is 24 fps; RealityKit
interpolates these original samples at display refresh rate.
"""
import bpy
import hashlib
import json
import struct
from pathlib import Path
from mathutils import Vector

base = Path(__file__).resolve().parents[2]
assets = base / 'assets/aero/meshy'
out = base / 'build/blender/meshy-native'
out.mkdir(parents=True, exist_ok=True)
source = assets / 'Aero_Meshy_Native.glb'
with source.open('rb') as f:
    header = f.read(20)
    gltf = json.loads(f.read(struct.unpack_from('<I', header, 12)[0]))
assert gltf['animations'] and len(gltf['skins'][0]['joints']) == 28

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.name = 'Aero Meshy Native Animations'
scene.render.fps = 24
bpy.ops.import_scene.gltf(filepath=str(source))
characters = list(bpy.context.selected_objects)
arm = next(o for o in characters if o.type == 'ARMATURE')
meshes = [o for o in characters if o.type == 'MESH']
arm.data.pose_position = 'REST'
bpy.context.view_layer.update()
depsgraph = bpy.context.evaluated_depsgraph_get()
points = [o.matrix_world @ Vector(v) for o in meshes
          for v in o.evaluated_get(depsgraph).bound_box]
low = Vector(tuple(min(p[i] for p in points) for i in range(3)))
high = Vector(tuple(max(p[i] for p in points) for i in range(3)))
root = bpy.data.objects.new('MeshyNativeRoot', None)
scene.collection.objects.link(root)
for o in characters:
    if o.parent is None:
        o.parent = root
scale = 1.9 / (high.z - low.z)
root.scale = (scale,) * 3
root.location = (-((low.x + high.x) / 2) * scale,
                 -((low.y + high.y) / 2) * scale, -low.z * scale)
bpy.context.view_layer.update()

def export(name, animated):
    bpy.ops.object.select_all(action='DESELECT')
    for o in [root, arm, *meshes]:
        o.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.wm.usd_export(filepath=str(out / (name + '.usdc')),
        selected_objects_only=True, export_animation=animated, export_armatures=True,
        export_materials=not animated, export_normals=True, export_uvmaps=True,
        export_textures_mode='NEW', overwrite_textures=True,
        export_lights=False, export_cameras=False, convert_orientation=False,
        root_prim_path='/Aero', triangulate_meshes=True)

export('rest', False)
arm.data.pose_position = 'POSE'
animation = arm.animation_data
animation.action = None
report = {'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
          'fps': 24, 'clips': {}, 'sourceSamples': {}}
camera = Vector((-.65, 1.05, 4.7))
forward = (Vector((0, .97, 0)) - camera).normalized()
right = forward.cross(Vector((0, 1, 0))).normalized()
up = right.cross(forward)

def joint_path(bone):
    return '/'.join(b.name.replace(':', '_') for b in [*reversed(bone.parent_recursive), bone])

for clip in gltf['animations']:
    name = clip['name']
    duration = max(gltf['accessors'][s['input']]['max'][0] for s in clip['samplers'])
    track = next(t for t in animation.nla_tracks if t.name == name)
    for t in animation.nla_tracks:
        t.mute = t != track
    strip = track.strips[0]
    # GLTF import starts at frame 1. Never scale or edit its action or NLA strip.
    count = round(duration * scene.render.fps)
    assert abs(strip.frame_end - strip.frame_start - count) < 0.001
    scene.frame_start = round(strip.frame_start)
    scene.frame_end = scene.frame_start + count
    report['clips'][name] = {'duration': count / 24, 'frames': count + 1}
    reference = []
    for offset in sorted({0, count // 2, count}):
        scene.frame_set(scene.frame_start + offset)
        bpy.context.view_layer.update()
        joints = {}
        for bone in arm.pose.bones:
            local = bone.parent.matrix.inverted() @ bone.matrix if bone.parent else bone.matrix
            translation, rotation, scaling = local.decompose()
            joints[joint_path(bone)] = [*translation, rotation.x, rotation.y, rotation.z, rotation.w, *scaling]
        reference.append({'time': offset / 24, 'joints': joints})
    report['sourceSamples'][name] = reference
    # Frame the full supplied motion, including its original root translation.
    # Camera metadata never changes any bone, action or skinning weight.
    vertical = horizontal = 0
    for offset in range(count + 1):
        scene.frame_set(scene.frame_start + offset)
        bpy.context.view_layer.update()
        depsgraph = bpy.context.evaluated_depsgraph_get()
        for mesh in meshes:
            for corner in mesh.evaluated_get(depsgraph).bound_box:
                point = mesh.matrix_world @ Vector(corner)
                relative = Vector((point.x, point.z, -point.y)) - camera
                depth = relative.dot(forward)
                assert depth > .1
                vertical = max(vertical, abs(relative.dot(up)) / depth)
                horizontal = max(horizontal, abs(relative.dot(right)) / depth)
    report['clips'][name]['framing'] = {'verticalTan': vertical * 1.1,
                                      'horizontalTan': horizontal * 1.1}
    scene.frame_set(scene.frame_start)
    export(name, True)

# A regular editable Blender document, with all source tracks preserved.
for t in animation.nla_tracks:
    t.mute = t.name != 'Big_Wave_Hello'
wave = next(t for t in animation.nla_tracks if t.name == 'Big_Wave_Hello').strips[0]
scene.frame_start, scene.frame_end = round(wave.frame_start), round(wave.frame_end)
scene.frame_set(scene.frame_start)
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(assets / 'Aero_Meshy_Native.blend'))
(assets / 'native-inspection.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'nativeAnimations': report['clips'], 'sourceSHA256': report['sourceSHA256']}))
