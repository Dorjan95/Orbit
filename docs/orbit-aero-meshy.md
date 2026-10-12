# Aero: animazioni originali Meshy in Orbit

La mascotte usa il nuovo download dell’utente `Meshy_AI_Neon_Buddy_All_Animations_the_real.glb`.
Copia invariata: `assets/aero/meshy/Aero_Meshy_Native.glb`, SHA256
`67b0846e7934b7abca91d262f0d8bc3a0d52e6927c95fa50e4514cff203bf101`.
Il documento modificabile `Aero_Meshy_Native.blend` conserva tutte le 12 azioni,
le texture, la geometria e i pesi originali. La scala esterna normalizza il modello
a 1,9 m; non sono state create o corrette pose, traiettorie IK o keyframe.
I precedenti gesti creati in Blender sono archiviati e non usati dal renderer corrente.

## Clip disponibili

| Clip originale | Durata |
| --- | ---: |
| Running | 0,6667 s |
| Walking | 1,0417 s |
| Big_Wave_Hello | 5,3333 s |
| Big_Heart_Gesture | 6,2083 s |
| Excited_Walk_F | 9,75 s |
| FunnyDancing_03 | 8 s |
| RunFast | 0,5 s |
| Shot_and_Slow_Fall_Backward | 4,4167 s |
| Sit_Cross_Legged_on_Floor | 2,5 s |
| Stand_to_Sit_Transition_M | 4,75 s |
| Wave_One_Hand | 4,125 s |
| situps | 2,2917 s |

Il file non contiene una partenza sui 100 metri né un gesto di mano al mento.
Per impostazione predefinita: saluto ampio all’apertura, transizione da in piedi a seduto per l’ascolto,
seduto a gambe incrociate per il ragionamento, camminata durante il lavoro e danza
al completamento. Gli altri stati mantengono una posa in piedi ricavata dal primo
fotogramma del saluto con una mano. Risposta, Domanda e Problema mostrano rispettivamente
un fumetto, un punto interrogativo e un triangolo di avviso sopra il personaggio. Queste associazioni sono scelte di interfaccia,
non animazioni aggiunte al modello.

In **Impostazioni → Mascotte → Animazioni per ogni stato** si può associare ciascuna
clip a saluto, ascolto, ragionamento, risposta, lavoro, successo, domanda e problema,
oppure scegliere la posa statica in piedi. Le assegnazioni vengono salvate e si
possono ripristinare. Le impostazioni delle versioni precedenti restano compatibili. Le assegnazioni
alla vecchia clip `Step_to_Sit_Transition` vengono migrate a
`Stand_to_Sit_Transition_M`; quelle a clip rimosse tornano al valore predefinito
dello stato. Il catalogo contiene solo le animazioni del download attuale.

Ascolto e ragionamento eseguono la clip una volta e mantengono l’ultimo fotogramma.
Un aggiornamento della trascrizione o del progresso non riavvia il movimento.
Solo camminata, corsa e corsa veloce si ripetono durante lo stato di lavoro.
Saluto e successo hanno la durata completa della clip scelta. L’anteprima 3D
mostra tutte le 12 clip con pausa, cursore e riprova, senza ciclo automatico.
Rispetta Riduci movimento di macOS e non avvia il microfono.

## Runtime e conversione

`OrbitModels/AeroMeshy.usdz` contiene una mesh, scheletro di 28 giunti e texture PBR.
`AeroMeshyMotion.json` contiene le trasformazioni locali dei giunti, schema 1,
24 fps originali, interpolati a 60 Hz con slerp per le rotazioni. Nessuna durata viene
accelerata o accorciata. I campioni finali ripetuti omessi dall’ottimizzazione USD
vengono valutati esplicitamente per conservare gli estremi temporali del GLB.
L’orientamento da Blender Z-up a RealityKit Y-up è applicato al contenitore,
non alle trasformazioni locali dello scheletro.

Ogni viewport clona il modello: scorrere l’anteprima non cambia la mascotte sul desktop.
Il raccordo tra stati dura 0,18 s e l’anteprima applica direttamente il campione.
I movimenti del bacino e gli spostamenti contenuti nelle clip restano originali.
L’inquadratura di ogni clip viene calcolata dagli ingombri della mesh deformata
su tutti i fotogrammi, con margine del 10%, e adattata al rapporto della viewport:
la camera resta ferma durante la riproduzione e non taglia piedi o braccia.
Le vecchie sequenze a immagini restano esclusivamente come fallback se il modello
3D non può essere caricato; il vecchio studio procedurale non è il modello corrente.

## Riproduzione e verifica

```sh
blender --background --python tools/blender/import_native_meshy.py
python3 -m venv build/blender/usd-venv
build/blender/usd-venv/bin/python -m pip install usd-core
build/blender/usd-venv/bin/python tools/blender/package_native_meshy.py
swift test
JARVIS_SIGN=adhoc ./scripts/build-app.sh
```

Il packaging confronta campioni iniziali, intermedi e finali di ogni clip con matrici
locali dei pose-bone valutate direttamente da Blender sul GLB importato.
Errore numerico massimo rilevato: 3,6 × 10⁻⁶. La fixture indipendente
`Tests/JarvisTests/Fixtures/MeshyNativeSource.json` consente di verificare la stessa
corrispondenza durante i test del renderer. Verificati anche durata e catalogo di
tutte le clip, mancata ripetizione dell’ascolto, isolamento delle anteprime,
raccordo tra stati, riduzione movimento, clock di ingresso e persistenza delle
assegnazioni. La suite include regressioni per le animazioni originali e test facoltativi
per i servizi esterni. Esegui `swift test` per il risultato della versione corrente.

## Immagini della documentazione

Dopo aver ricreato il documento Blender, puoi renderizzare le pose effettive:

```sh
blender --background assets/aero/meshy/Aero_Meshy_Native.blend --python tools/blender/render_readme.py
python3 -m pip install Pillow
python3 tools/make_readme_images.py
```

Il compositore usa i font di sistema macOS. Per la licenza degli asset, vedi
[LICENSE.md](../assets/aero/meshy/LICENSE.md).
