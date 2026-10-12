"""Package native Meshy clips and verify them against the imported source rig."""
import json
import math
from pathlib import Path
from pxr import Usd, UsdGeom, UsdSkel, UsdUtils, Sdf

base = Path(__file__).resolve().parents[2]
source = base / 'build/blender/meshy-native'
target = base / 'Sources/Jarvis/Resources/OrbitModels'
report = json.loads((base / 'assets/aero/meshy/native-inspection.json').read_text())
tracks = {}
names = None
max_error = 0
for name, expected in report['clips'].items():
    stage = Usd.Stage.Open(str(source / (name + '.usdc')))
    skeleton = next(UsdSkel.Skeleton(p) for p in stage.Traverse() if p.IsA(UsdSkel.Skeleton))
    animation = next(UsdSkel.Animation(p) for p in stage.Traverse() if p.IsA(UsdSkel.Animation))
    joints = list(skeleton.GetJointsAttr().Get())
    animated = list(animation.GetJointsAttr().Get())
    if names is None:
        names = joints
    assert names == joints and set(names) == set(animated) and len(names) == 28
    indices = [animated.index(n) for n in names]
    authored_samples = animation.GetRotationsAttr().GetTimeSamples()
    assert stage.GetTimeCodesPerSecond() == report['fps'] == 24
    # USD omits a repeated final value. Evaluate every original frame, including
    # that held endpoint, instead of shortening the supplied clip.
    start, end = stage.GetStartTimeCode(), stage.GetEndTimeCode()
    assert round(end - start) + 1 == expected['frames']
    assert all(start <= t <= end and abs(t - round(t)) < 1e-8 for t in authored_samples)
    samples = [start + i for i in range(expected['frames'])]
    frames = []
    for t in samples:
        translations = animation.GetTranslationsAttr().Get(t)
        rotations = animation.GetRotationsAttr().Get(t)
        scales = animation.GetScalesAttr().Get(t)
        frame = []
        for i in indices:
            q = rotations[i]
            values = [*translations[i], *q.GetImaginary(), q.GetReal(), *scales[i]]
            assert all(math.isfinite(float(v)) for v in values)
            frame.append([round(float(v), 7) for v in values])
        frames.append(frame)
    tracks[name] = {'duration': expected['duration'], 'frames': frames, 'framing': expected['framing']}
    # Compare first/middle/last samples with independent Blender pose-bone
    # matrices evaluated directly from the imported, unedited GLTF actions.
    for reference in report['sourceSamples'][name]:
        frame = frames[round(reference['time'] * 24)]
        for joint, actual in zip(names, frame):
            expected_pose = reference['joints'][joint]
            position_error = max(abs(a-b) for a,b in zip(actual[:3], expected_pose[:3]))
            scale_error = max(abs(a-b) for a,b in zip(actual[7:], expected_pose[7:]))
            dot = abs(sum(a*b for a,b in zip(actual[3:7], expected_pose[3:7])))
            max_error = max(max_error, position_error, scale_error, abs(1-dot))
            assert position_error < 0.0001 and scale_error < 0.001 and dot > 0.9999, (name, joint, actual, expected_pose)

motion = {'schemaVersion': 1, 'fps': 24, 'jointNames': names, 'clips': tracks,
          'sourceSHA256': report['sourceSHA256']}
(target / 'AeroMeshyMotion.json').write_text(json.dumps(motion, separators=(',', ':')) + '\n')
rest = source / 'rest.usdc'
stage = Usd.Stage.Open(str(rest))
# Idempotent: avoid stacking orientation changes on subsequent packaging runs.
xform = UsdGeom.Xform(stage.GetDefaultPrim())
if UsdGeom.GetStageUpAxis(stage) == UsdGeom.Tokens.z:
    xform.AddRotateXOp(opSuffix='orbitYUp').Set(-90)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
UsdGeom.SetStageMetersPerUnit(stage, 1)
stage.GetRootLayer().Save()
asset = target / 'AeroMeshy.usdz'
assert UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(rest)), str(asset))

# Native-source regression fixture: independent samples, not a copy of runtime JSON.
fixture = {'sourceSHA256': report['sourceSHA256'], 'fps': 24,
           'clips': report['clips'], 'sourceSamples': report['sourceSamples']}
(base / 'Tests/JarvisTests/Fixtures/MeshyNativeSource.json').write_text(json.dumps(fixture, separators=(',', ':')) + '\n')
print(json.dumps({'assetBytes': asset.stat().st_size, 'clips': report['clips'],
                  'maxSourcePoseError': max_error, 'motionBytes': (target/'AeroMeshyMotion.json').stat().st_size}))
