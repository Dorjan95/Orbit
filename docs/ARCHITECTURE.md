# Architettura

Orbit è un package Swift con due moduli e due target di test.

| Componente | Responsabilità |
| --- | --- |
| `OrbitCore/Domain.swift` | Progetti, impostazioni, sessioni, stati e riconoscimento della wake phrase |
| `Storage.swift` | Stato JSON atomico, segreto Fish e importazione del vecchio formato dati |
| `ProcessStream.swift` | Lancio senza shell, stdin, drenaggio concorrente stdout/stderr, cancellazione |
| `CLI.swift` | Ricerca degli eseguibili, argomenti Codex/Claude e decoding degli eventi JSONL |
| `CodexSession.swift`, `CodexProtocol.swift` | Trasporto app-server, richieste interattive, validazione dei moduli e catalogo MCP |
| `PromptViews.swift` | Autorizzazioni, domande, moduli e connessioni nelle schede SwiftUI |
| `Routing.swift` | Prompt dell’interprete, schema JSON e validazione dei riferimenti |
| `Services.swift` | Client Fish e discovery dei modelli Ollama/LM Studio |
| `OrbitDesktop/Controller.swift` | Coordinamento sul MainActor, limite di concorrenza e code per sessione |
| `Audio.swift` | Speech, AVAudioEngine, Fish Audio e sintetizzatore di sistema |
| `Shortcuts.swift` | Hotkey Carbon, eventi di pressione e rilascio |
| `OrbitApp.swift` | Barra menu, finestra principale e pannelli flottanti |
| `Mascot.swift` | Player RealityKit del modello e delle trasformazioni articolari |
| `Views.swift`, `ConfigurationViews.swift`, `MascotSettings.swift` | Interfaccia SwiftUI |
| `Documentation.swift` | Immagini delle schermate con dati dimostrativi, senza audio o agenti |

## Identità delle sessioni

L’UUID Orbit identifica una scheda del pannello. L’ID restituito dal CLI identifica il contesto dell’agente. Non sono intercambiabili. Una sessione conserva una copia del provider, del modello, dei permessi e della cartella scelti alla partenza. La selezione globale successiva riguarda solo i nuovi lavori.

Un interprete produce una decisione usando soltanto gli ID presenti nel registro. La validazione rifiuta ID sconosciuti, progetti incoerenti e continuazioni senza destinatario. La risoluzione dell’ambiguità nel linguaggio naturale dipende anche dal modello; il prompt richiede chiarimento quando più destinatari sono plausibili. Il campo di risposta di una scheda passa direttamente il suo UUID al coordinatore.

Lo scheduler usa una coda globale di lavori in attesa e una coda di richieste per ciascuna sessione. Un solo processo CLI può lavorare su una sessione in un dato momento. Il coordinatore limita il numero totale di processi a 1–6. Una richiesta accodata riprende l’ID CLI esistente dopo un turno completato; resta in attesa se il turno fallisce o necessita di input.

I PID non sono salvati nello stato. La cancellazione agisce esclusivamente sul processo creato dall’istanza `ProcessStream`, segnalando il suo gruppo solo quando il PID coincide con il group ID. I comandi non passano attraverso una shell, salvo i file `.command` aperti su richiesta esplicita tramite il pulsante Terminale o Login; gli argomenti in questi file sono quotati.

## Confini dell’interprete

L’interprete Codex lavora in una cartella temporanea, con sandbox di sola lettura, senza configurazione utente, shell, ricerca web, app e plugin. Usa `--ephemeral` e `--output-schema`. Claude usa modalità print, schema JSON, nessuno strumento e nessuna configurazione MCP. L’autenticazione rimane quella del CLI. Prompt, memoria e testo dei progetti sono marcati come dati; gli ID restituiti vengono controllati prima di avviare un agente.

I worker hanno strumenti e permessi del progetto. L’accesso completo è una scelta esplicita. Le integrazioni cloud seguono la configurazione del CLI; quelle dei lavori locali sono opzionali.

## Asset di Aero

Il GLB originale contiene lo scheletro e i clip Meshy. La versione USDZ conserva la mesh, i materiali e lo skinning. Il file JSON contiene trasformazioni locali, campionate a 24 fps:

```text
schemaVersion: 1
fps: 24
sourceSHA256: hash del GLB sorgente
jointNames: percorsi delle 28 articolazioni
clips:
  <nome>:
    duration: secondi
    framing: verticalTan, horizontalTan
    frames:
      [ [tx, ty, tz, qx, qy, qz, qw, sx, sy, sz], ... ]
```

`jointNames` usa i percorsi gerarchici RealityKit. Ogni frame deve avere lo stesso numero di articolazioni. Traslazioni e scale usano interpolazione lineare; le rotazioni usano slerp. All’ingresso di un nuovo stato, il player miscela dalla posa corrente per 0,18 secondi. L’epoca dell’animazione cambia all’ingresso dello stato o a una ripetizione esplicita, non a ogni aggiornamento di testo.

Il lavoro ripete il clip. Gli altri gesti mantengono l’ultimo frame. Gli stati senza clip assegnato usano la posa in piedi di `Wave_One_Hand` e un’icona quando prevista. Con Riduci movimento il lavoro resta al primo frame e gli altri gesti alla posa finale. Il preview ha il proprio tempo, pausa e slider, separati dal player desktop.

Per sostituire il personaggio occorre aggiornare GLB, USDZ e JSON coerentemente. Si può preparare il modello in Blender, esportare USDZ con skinning e campionare le trasformazioni locali delle articolazioni nello schema sopra. Gli asset runtime sono già inclusi: Blender non è necessario per compilare o usare Orbit.

## Stato e compatibilità

`state.json` è scritto con sostituzione atomica e date ISO 8601. Le impostazioni mancanti ricevono i valori predefiniti. Se lo stato è illeggibile, Orbit conserva il file e sospende il salvataggio anziché sovrascriverlo con valori vuoti.

L’importatore del precedente prototipo è solo un adattatore di dati. Non include vecchi sorgenti e non esegue il precedente programma. I lavori che risultavano in corso vengono marcati come interrotti; gli ID CLI restano disponibili per la ripresa. Le cartelle personalizzate dei test non attivano la migrazione.

## Build e distribuzione

`scripts/build.sh` produce `build/Orbit.app`, copia il resource bundle SwiftPM e applica una firma ad hoc. `scripts/install.sh` conserva la precedente app prima di installare la nuova. L’identità dell’app è `io.github.dorjan95.orbit`; i permessi di microfono e Speech sono quindi separati da quelli del vecchio prototipo.

## Browser dei lavori Codex

La navigazione usa Playwright MCP 0.0.83 e MCP SDK 1.32.1, con dipendenze bloccate nel lockfile incluso nelle risorse. Node.js e Google Chrome sono prerequisiti della funzione opzionale. Il modulo viene installato nella cartella dati di Orbit e non aggiunge file alle repository registrate.

`BrowserCoordinator` mantiene un host Node per sessione Orbit. L’host espone MCP Streamable HTTP solo su `127.0.0.1`, su una porta assegnata dal sistema, con un token casuale per quel processo. Verifica bearer token, Host e assenza di Origin prima di accettare una richiesta. I token restano in memoria e vengono passati ai lavori tramite variabile d’ambiente; la configurazione MCP è specifica dell’invocazione CLI. L’interprete non riceve questi strumenti: riceve invece un elenco delle capacità effettivamente configurate nell’app.

Il browser è un contesto Chrome persistente per ID sessione, gestito dall’host e riutilizzato dai client MCP successivi. La fine di un turno CLI non chiude il contesto; un login manuale o una domanda possono quindi essere completati prima di riprendere la stessa sessione. La chiusura della scheda sessione o dell’app termina i processi gestiti. Ogni sessione concorrente ha un profilo distinto e non importa i dati del Chrome personale. Il server rifiuta strumenti esterni all’elenco di navigazione e interazione, tra cui esecuzione arbitraria di JavaScript e upload.

Gli strumenti dell’host Orbit sono approvati nella configurazione del solo server `orbit_browser`, così il browser può navigare mentre il suo host mostra le proprie conferme native. La sandbox dei file del worker conserva la scelta del progetto. L’host aggiunge una verifica degli elementi prima delle interazioni: usa i riferimenti dello snapshot, blocca campi riconoscibili come credenziali e chiede conferma nell’app per invii riconoscibili. La risposta alla conferma usa un endpoint locale autenticato e scade dopo 90 secondi. È una protezione aggiuntiva, non una classificazione completa degli effetti di ogni sito. Il contesto Chrome mantiene la sandbox Chromium attiva.

I test Swift verificano configurazione del worker, isolamento dell’interprete e assenza di token negli argomenti. Il test Node verifica il protocollo MCP, autenticazione, rifiuto di richieste da pagine web e blocco degli strumenti esclusi. La verifica dell’app comprende la richiesta di apertura di una pagina pubblica e l’ispezione della finestra browser.

## Sessioni Codex interattive

`CodexSession` usa NDJSON bidirezionale su stdio con `codex app-server`. Esegue initialize, thread/start o thread/resume, lettura del catalogo MCP e turn/start. Le notifiche di completamento del turno determinano lo stato del lavoro; l’uscita del processo senza completamento è un errore. Non c’è un fallback automatico a exec che potrebbe duplicare azioni.

Ogni turno ha il proprio processo e browser MCP; il thread ID persiste nella sessione Orbit. Le richieste server sono identificate da connessione, ID JSON, thread e turno, senza condividere autorizzazioni tra repository. Comandi e file ricevono soltanto accept/decline; permessi aggiuntivi usano scope turn. Le domande e i moduli rimangono in memoria e vengono rimossi alla risposta, risoluzione, cancellazione o chiusura. Le risposte ai moduli non sono scritte nei log Orbit; possono comparire nella cronologia del provider se il tool le restituisce al modello.

Il catalogo delle impostazioni usa un thread ephemeral senza avviare un turno del modello. Il catalogo per sessione viene acquisito prima del turno. L’interprete rimane privo di strumenti: invia le richieste operative al worker. I modelli locali senza integrazioni hanno una CODEX_HOME privata e persistente per sessione, con app/plugin/web disabilitati. Il browser esplicitamente abilitato è collegato solo attraverso la configurazione specifica della connessione.
