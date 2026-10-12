# Aero — sorgente 3D corrente

`Aero_Meshy_Native.glb` è il modello di Aero generato con Meshy per Orbit,
con rig a 28 giunti e 12 animazioni originali. È conservato senza modifiche:

```text
SHA256 67b0846e7934b7abca91d262f0d8bc3a0d52e6927c95fa50e4514cff203bf101
```

L'app carica la conversione `AeroMeshy.usdz` e i campioni in
`AeroMeshyMotion.json` dalla cartella `Sources/Jarvis/Resources/OrbitModels`.
Non richiede Blender o Python per funzionare.

Gli script pubblicati sono portabili e ricavano la cartella del progetto dalla
propria posizione. Gli asset generati, i documenti Blender e i prototipi precedenti
non vengono inclusi nella repository. Il documento Blender corrente si ricrea con
lo script di importazione.

Per licenza degli asset, consulta [LICENSE.md](LICENSE.md). Per clip, conversione
RealityKit e riproduzione, consulta [la guida 3D](../../../docs/orbit-aero-meshy.md).
