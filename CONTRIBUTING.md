# Contribuire a Orbit

Prima di riutilizzare o contribuire al codice, consulta [LICENSING.md](LICENSING.md):
il codice ereditato da Jarvis non ha attualmente una licenza open source dichiarata.

## Segnalare un problema

Apri una issue con versione macOS, versione Swift e CLI, provider usato,
passaggi per riprodurre il comportamento e risultato atteso.
Per errori vocali, indica se usavi attivazione vocale, scorciatoia o mascotte.
Per sessioni, indica l'agente e il livello di permessi senza condividere dati privati.

Non pubblicare chiavi API, token, conversazioni private o log completi non verificati.
Usa un progetto dimostrativo quando possibile.

## Proporre una modifica

1. Crea un branch con una modifica circoscritta.
2. Spiega il problema e il comportamento risultante nella pull request.
3. Esegui `swift test` e `JARVIS_SIGN=adhoc ./scripts/build-app.sh` su macOS.
4. Per cambiamenti dell'interfaccia, verifica le schermate, i diversi stati e Riduci movimento.
5. Per la mascotte, verifica anche le dimensioni minime e il trascinamento su più schermi.

I test reali Codex e Ollama sono facoltativi: non sono necessari per ogni pull request.
Non modificare o registrare i dati dell'utente per costruire fixture.

## Aggiornare le immagini

Le schermate della documentazione si esportano con dati fittizi:

```sh
ORBIT_DOCS_OUTPUT="$PWD/docs/images" swift test --filter DocumentationSnapshotTests
```

I render della mascotte si producono dal modello corrente con Blender;
`tools/make_readme_images.py` compone il banner e la tavola delle pose con Pillow.
Non usare i prototipi storici come se rappresentassero la mascotte attuale.
