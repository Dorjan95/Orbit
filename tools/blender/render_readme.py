"""Render the actual Meshy mascot for documentation, without changing its rig.

blender --background assets/aero/meshy/Aero_Meshy_Native.blend \
    --python tools/blender/render_readme.py
"""
import bpy
from pathlib import Path
from mathutils import Vector

base = Path(__file__).resolve().parents[2]
output = base / 'docs/images'
output.mkdir(parents=True, exist_ok=True)
scene = bpy.context.scene
try:
    scene.render.engine = 'BLENDER_EEVEE_NEXT'
except TypeError:
    scene.render.engine = 'BLENDER_EEVEE'
scene.render.resolution_x = 600
scene.render.resolution_y = 800
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.film_transparent = True
scene.view_settings.view_transform = 'AgX'
scene.world = bpy.data.worlds.new('Documentation Studio')
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (.15, .16, .18, 1)
scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value = .35

def aim(obj, point):
    obj.rotation_euler = (Vector(point) - obj.location).to_track_quat('-Z', 'Y').to_euler()

camera_data = bpy.data.cameras.new('Documentation Camera')
camera = bpy.data.objects.new('Documentation Camera', camera_data)
scene.collection.objects.link(camera)
camera.location = (-.32, -5.0, 1.35)
aim(camera, (0, 0, .98))
camera_data.type = 'ORTHO'
camera_data.ortho_scale = 2.45
scene.camera = camera

for name, position, energy, size in [
    ('Key', (-3, -4, 4), 700, 3),
    ('Fill', (3, -2, 2), 400, 2),
    ('Rim', (1, 2, 3), 650, 2),
]:
    data = bpy.data.lights.new(name, 'AREA')
    data.energy, data.shape, data.size = energy, 'DISK', size
    lamp = bpy.data.objects.new(name, data)
    scene.collection.objects.link(lamp)
    lamp.location = position
    aim(lamp, (0, 0, 1))

rig = next(o for o in scene.objects if o.type == 'ARMATURE')
rig.data.pose_position = 'POSE'
rig.animation_data.action = None
for filename, clip, offset in [
    ('aero-standing.png', 'Wave_One_Hand', 0),
    ('aero-greeting.png', 'Big_Wave_Hello', 65),
    ('aero-thinking.png', 'Sit_Cross_Legged_on_Floor', 60),
]:
    for track in rig.animation_data.nla_tracks:
        track.mute = track.name != clip
    track = next(t for t in rig.animation_data.nla_tracks if t.name == clip)
    scene.frame_set(round(track.strips[0].frame_start) + offset)
    scene.render.filepath = str(output / filename)
    bpy.ops.render.render(write_still=True)
