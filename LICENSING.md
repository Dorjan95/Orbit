# Stato delle licenze

## Codice ereditato

Orbit deriva dalla repository pubblica
[riccardo-belli/jarvis-assistente-personale](https://github.com/riccardo-belli/jarvis-assistente-personale),
commit iniziale `2a66ce4`. Alla preparazione di questa pubblicazione (6 ottobre 2026),
la repository di partenza non dichiara una licenza e non contiene un file `LICENSE`.
Il suo README cita anche [VoiceMode](https://github.com/albertshiney/VoiceMode).

Non viene applicata una licenza MIT, Apache o altra licenza open source all'intero
codice ereditato. Le modifiche e il nuovo nome non sostituiscono una concessione
di licenza da parte dei titolari dei contributi precedenti.

La cronologia Git conserva il commit iniziale del prototipo e la precedente
implementazione Orbit 1.4, disponibile anche nel branch `archive/orbit-1.4`.
La licenza MIT di quella implementazione separata non viene applicata al codice
ereditato da Jarvis in questa release.
Il progetto completo non è attualmente presentato come software con licenza open source.
Vedi la [documentazione GitHub sulle licenze](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository).

## Aero e immagini della documentazione

La mascotte corrente è stata generata per il progetto dal maintainer con un piano
Meshy a pagamento. Le condizioni di Meshy distinguono gli asset di piani gratuiti
da quelli generati con piani a pagamento: [documentazione Meshy](https://help.meshy.ai/en/articles/16102098-can-i-use-meshy-assets-commercially).

Il maintainer rende disponibili il modello Aero fornito per Orbit, le sue
conversioni e i render della documentazione sotto
[Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/),
con attribuzione a **Dorjan95 / Orbit**. La concessione riguarda questi asset,
non cambia lo stato della licenza del codice ereditato.

File della mascotte corrente: `assets/aero/meshy/Aero_Meshy_Native.glb`,
`Sources/Jarvis/Resources/OrbitModels/AeroMeshy.usdz` e `AeroMeshyMotion.json`.
Il GLB originale è invariato; le conversioni normalizzano scala e orientamento
e campionano le animazioni per il runtime RealityKit. I render usano il modello reale.

I modelli vocali Fish Audio non sono distribuiti qui. I nomi dei servizi e degli
strumenti nei documenti servono a identificare le integrazioni.
