# Runtime degli agenti in Orbit

Orbit applica due idee studiate in DeepSeek Harness: un contratto comune per i
backend e una distinzione persistente tra sessione, richiesta e turno in esecuzione.
Il runtime è Swift e usa le CLI native di Codex e Claude Code. L'interprete vocale conserva la sua configurazione
separata da quella degli agenti che eseguono il lavoro.

## Backend

`AgentBackend` espone avvio, capacità, annullamento, chiusura e risposta ai permessi. `AgentRunner`
implementa il trasporto headless; `ClaudeCLIAdapter` e `CodexCLIAdapter` contengono
argomenti e parser specifici delle CLI. I comandi, l'autenticazione e i server MCP
continuano a essere quelli già usati da Orbit.

I backend supportano la ripresa mediante identificativo remoto. `NativeAgentBackend`
collega Codex app-server e Claude Code tramite i protocolli delle CLI.
I seguiti vengono accodati.
**Reindirizza** interrompe e riprende il lavoro con una nuova istruzione nei due
collegamenti interattivi; il trasporto headless mantiene i seguiti FIFO.
Le capacità descrivono l'integrazione di Orbit, non tutte le funzioni delle CLI.

Gli eventi letti dal subprocess hanno un unico consumatore `AsyncStream` sul
MainActor: identificativo remoto e risultato finale vengono elaborati prima
dell'uscita. Ogni callback porta anche l'identificativo del turno, per impedire
a eventi tardivi di modificare un turno successivo della stessa sessione.

## Codex e Claude Code interattivi

Queste funzioni riprendono l'architettura studiata in DeepSeek Harness, ma il
runtime di Orbit è Swift e non dipende da dsh né dalle API DeepSeek. In
**Impostazioni → Modelli → Sessioni e permessi** i controlli interattivi di Codex
e Claude Code sono attivi per le nuove sessioni. Disattivarli seleziona il
precedente trasporto headless. `AgentExecutionConfiguration.interactiveControls`
congela la scelta per ogni sessione; l'assenza del campo nelle sessioni vecchie
mantiene headless. La review indipendente usa sempre il backend in sola lettura.

- **Codex:** `codex app-server --listen stdio://`, handshake `initialize` /
  `initialized`, `thread/start` o `thread/resume`, poi `turn/start`.
  La modalità “Nel progetto” seleziona sandbox `workspace-write`, approvazioni
  `on-request` e revisore `user`. I delta e gli item diventano eventi comuni di
  Orbit. Solo `turn/completed` con stato `completed`, seguito dall'uscita pulita,
  può completare una richiesta. Per lo steering Orbit attende la risposta a
  `turn/interrupt`, lo stato terminale `interrupted` e l'uscita; poi riprende lo
  stesso thread con la nuova istruzione. Non usa l'iniezione nativa `turn/steer`.
- **Claude Code:** stdin e stdout `stream-json`, `--permission-prompt-tool stdio`,
  handshake `control_request:initialize`. “Nel progetto” usa la modalità standard
  dei permessi; non è un sandbox OS introdotto da Orbit. I callback `can_use_tool`
  vengono esposti all'utente e ricevono `allow` con l'input originale oppure
  `deny`, senza aggiornamenti persistenti delle policy. Lo steering attende
  l'acknowledgement di `interrupt`, il risultato terminale e l'uscita pulita,
  poi avvia `--resume` con lo stesso UUID. Un errore estraneo all'interruzione
  blocca la ripresa automatica.

Le CLI conservano autenticazione, trascrizioni, strumenti e configurazione.
Orbit non copia token e non richiede una nuova chiave API. Un rifiuto dell'account,
un limite d'uso o una policy organizzativa resta un errore del provider.
I protocolli sono verificati con Codex `0.162.0-alpha.17.2` e Claude Code `2.1.143`.
Le prove reali di Codex eseguite sul Mac di sviluppo hanno superato approvazione
e steering con ripresa dello stesso contesto tramite l'accesso esistente.
Per Claude, consenso, rifiuto e steering sono verificati con il peer locale;
le prove con il modello restano soggette all'accesso e alle policy dell'account.
Una prova simulata non dimostra la riuscita end-to-end con un provider reale.
Riferimenti: [Codex app-server](https://learn.chatgpt.com/docs/app-server),
[Claude streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)
e [protocollo del SDK Python ufficiale](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/query.py).

I permessi di comando/file offrono solo consenso per la richiesta o rifiuto.
Le richieste Codex `item/permissions/requestApproval` possono concedere il solo
profilo richiesto per il turno corrente: la scheda lo indica esplicitamente;
`acceptForSession`, modifiche di execpolicy e grant di sessione non vengono offerti.
IDs numerici e stringa restano distinti. Il consenso viene salvato nel journal
prima della consegna; una consegna incerta non viene ripetuta. Richieste duplicate,
risultati incompleti e disconnessioni non diventano successi. Le interruzioni hanno
un limite di 10 secondi; il pulsante Ferma termina un peer non cooperativo entro
3 secondi. Dopo un'interruzione incerta la nuova direzione resta disponibile nella
coda, senza lancio automatico.

Prova in un progetto separato con permessi **Nel progetto**: avvia una richiesta,
usa **Reindirizza** mentre il lavoro è in corso e rispondi ai permessi nella
scheda della sessione. **Accesso completo** segue le policy di bypass delle CLI,
quindi non è adatto per provocare un dialogo di approvazione.

`NativeAgentIntegrationTests` copre consenso/rifiuto, steering con un permesso
pendente, identità del contesto, coda, interruzione non confermata, timeout
e workflow con review in sola lettura. I test comuni di `SessionRuntimeTests`
coprono il recupero dal riavvio senza ripetere decisioni di consenso.
Test facoltativi con login reali:

```sh
ORBIT_NATIVE_LIVE=1 ORBIT_NATIVE_AGENT=codex swift test --filter NativeAgentIntegrationTests/testRealInstalledCLIsCompleteUsingExistingLogin
ORBIT_NATIVE_LIVE=1 ORBIT_NATIVE_AGENT=claude swift test --filter NativeAgentIntegrationTests/testRealInstalledCLIsCompleteUsingExistingLogin
ORBIT_NATIVE_LIVE_CODEX=1 swift test --filter NativeAgentIntegrationTests/testRealCodexApprovalAndSteeringUsingExistingLogin
```

Per esportare le schermate dei controlli nativi con dati fittizi:

```sh
ORBIT_NATIVE_PREVIEW_DIR=/tmp/orbit-native-preview swift test --filter NativeAgentIntegrationTests/testNativeControlsPanelPreviews
```

## Compatibilità con i dati precedenti

L'integrazione esterna DeepSeek Harness è stata rimossa: nessun launcher `dsh`,
trasporto ACP, overlay o impostazione resta attivo. Codex e Claude conservano i
propri protocolli nativi, login, steering, approvazioni e workflow.

Il valore storico `agent: "deepseek"` resta decodificabile per non invalidare
`session-events.jsonl` e `sessions.json`. Le sessioni restano identificate come
**DeepSeek (storico)**, con risultati e identità originali: non vengono convertite
in contesti Codex o Claude. Turni pendenti vengono annullati, quelli avviati
interrotti e approvazioni pendenti scadute. Ripresa, risposta e steering sono
inibiti per queste sessioni, anche nei workflow che avevano solo un revisore
DeepSeek. Il log e la cartella del progetto restano consultabili.

Preferenze globali e progetti che selezionavano DeepSeek passano a Codex. I
progetti migrati usano **Nel progetto**; nome, percorso, alias e comando di verifica
rimangono invariati. Le vecchie impostazioni DeepSeek vengono ignorate e non
riscritte. Gli agenti disponibili nei selettori e nello schema vocale sono
soltanto Codex e Claude.

## Richieste e coda

Ogni `SessionTurn` ha un UUID, usato anche come identificativo della richiesta,
testo, date, codice di uscita e configurazione di esecuzione. La sessione mantiene
separatamente l'identificativo locale e quello del provider.

La configurazione viene fissata all'avvio della sessione; ogni richiesta conserva
anche le istruzioni di memoria presenti quando viene accettata. Nelle sessioni
precedenti a questa versione, i dati mancanti vengono fissati al primo seguito:
Orbit non può ricostruire il modello Claude originario se non era stato salvato.
Se la selezione è lasciata predefinita, Orbit continua a delegare il modello alla
CLI: non legge né fissa il modello effettivamente risolto dal provider.

Gli stati dei turni sono:

| Stato | Significato |
| --- | --- |
| `queued` | Accettato e salvato; non ancora inoltrato alla CLI |
| `dispatched` | Avvio registrato prima di creare il subprocess |
| `completed` | CLI uscita con codice zero, senza errore o blocco normalizzato |
| `failed` | Avvio, esecuzione o risultato del backend non riuscito |
| `blocked` | Il backend ha segnalato che serve un intervento dell'utente |
| `cancelled` | Richiesta annullata; per un turno attivo viene confermato all'uscita |
| `interrupted` | Il riavvio non consente di stabilire l'esito del turno avviato |

I seguiti partono in ordine FIFO dopo `completed`. Un errore segnalato dal backend
resta un errore anche se il processo termina con codice zero. `completed` descrive
l'esito del trasporto: non costituisce una verifica indipendente del lavoro svolto.

Un turno bloccato o fallito lascia la coda disponibile per **Riprendi coda**.
**Ferma** registra la richiesta di annullamento, cancella i turni non avviati e
interrompe il subprocess. Il runtime resta occupato fino al callback di uscita;
una nuova richiesta non può riattivarlo mentre si sta fermando. Il limite di
concorrenza conta i runtime, inclusi quelli in arresto.

## Persistenza e recupero

Nella directory dati di Orbit:

- `session-events.jsonl` contiene eventi di ciclo di vita versionati, numerati e
  append-only, ciascuno con la proiezione della sessione;
- `sessions.json` resta una vista compatibile delle sessioni recenti;
- `logs/<sessionID>.ndjson` conserva l'output grezzo delle CLI.

Accettazione, inoltro, avvio del processo, identificativo remoto, blocco, risultato,
uscita e annullamento producono eventi. Gli aggiornamenti transitori di attività
e testo usano la vista JSON e il log grezzo, senza aggiungere un evento per ogni
frammento. Il journal viene sincronizzato su disco prima di avviare lavoro esterno.
Se la scrittura fallisce, Orbit mostra l'errore e blocca ulteriori avvii.

Alla prima apertura, la migrazione dell'intera vista precedente è atomica. Ai
riavvii successivi, il journal prevale su una vista JSON vecchia o non valida.
Solo una coda di byte priva del terminatore di riga può essere scartata dopo una
scrittura interrotta; una riga completa corrotta o con versione sconosciuta blocca
gli avvii e conserva i file per l'analisi. Non viene eseguita una riparazione
automatica dei record completi.

I turni `dispatched` diventano `interrupted`; i turni `queued` conservano UUID e
contenuto. Nessuna richiesta viene rilanciata automaticamente al riavvio. Il PID
salvato non viene usato per terminare processi, perché potrebbe essere stato
riassegnato dal sistema. Occorre verificare il lavoro e gli eventuali processi
superstiti prima della ripresa esplicita. Non c'è una garanzia di esecuzione
esattamente una volta per gli effetti esterni delle CLI.

La vista conserva fino a 100 sessioni, proteggendo sempre quelle attive e con
richieste pendenti. Il journal conserva la storia: compattazione, adozione sicura
di processi superstiti e accesso da più istanze non fanno parte di questa tranche.
Il journal ha un solo proprietario, il `SessionStore` del coordinatore.

## Verifica del runtime

`SessionRuntimeTests` verifica migrazione, recupero da vista obsoleta, corruzione,
scritture incomplete, errori di persistenza, FIFO, annullamento, contesto remoto,
modelli e permessi fissati, blocchi Claude e ordinamento degli eventi finali.
Le CLI sono simulate in directory temporanee; non vengono chiamati servizi AI.
`RemovedProviderMigrationTests` verifica lettura dello storico, migrazione dei
progetti, conservazione dei dati nativi e rifiuto di qualsiasi rilancio
con il provider rimosso, anche per workflow con agenti misti.

Per esportare il pannello con dati fittizi:

```sh
ORBIT_RUNTIME_PREVIEW_DIR=/tmp/orbit-runtime-preview swift test --filter SessionRuntimeTests/testRecoveryPanelPreview
```

## Steering

**Reindirizza**, nel pannello e nella pagina Sessioni, è disponibile durante un
turno modificabile con i controlli interattivi Codex o Claude Code, compresa
l'implementazione o una correzione automatica di un workflow.

Orbit salva la nuova direzione con UUID e configurazione, revoca i permessi
pendenti e attende la conferma di interruzione, l'esito terminale e l'uscita pulita.
Solo allora riprende lo stesso contesto remoto con la nuova istruzione. I seguiti
già accettati restano in coda e le modifiche precedenti restano nel progetto.
Se la conferma manca, l'input resta per una ripresa esplicita. **Ferma** annulla
anche quel turno. Un secondo steering durante l'interruzione viene rifiutato.
Il comando vocale esplicito usa `steer`; `followup` accoda senza interrompere.

## Piano ed editor visuale del workflow

I nuovi workflow usano una definizione a nodi, salvata nelle impostazioni e congelata
nella sessione prima di avviare qualsiasi processo. Da **Impostazioni → Workflow →
Apri editor visuale** puoi configurare il percorso predefinito; **Sessioni → Nuovo
workflow → Configura nodi e modelli** modifica solo il lavoro che stai per avviare.
Anche l'avvio esplicito a voce usa la definizione salvata. I workflow precedenti
conservano il flusso a tre fasi e il loro budget originale, descritto sotto.

**Nuovo** crea un percorso libero vuoto: nessuna fase è obbligatoria. **Modelli di
partenza** offre Vuoto, Ricerca e Sviluppo controllato. Puoi eliminare qualsiasi
nodo, comprese le fasi standard, e scegliere **Inizio**. Eliminare una fase standard
converte il modello in percorso libero. Il nodo iniziale deve esistere e tutti i
nodi devono essere raggiungibili; un'uscita Riuscito senza collegamento conclude
il percorso. Il workflow Ricerca usa una sola Azione AI e non richiede Piano,
implementazione, review o verifica. I grafi salvati senza il nuovo campo `mode`
conservano il comportamento Sviluppo controllato.

Il modello **Sviluppo controllato** segue **Piano → Approva piano → Implementazione → Review → Verifica**.
Le uscite negative di Review e Verifica portano a **Correzione**, poi a una
nuova Review. Il Piano e la review usano contesti nuovi e gli stessi vincoli di
sola lettura dei revisori. Ogni nodo AI permette di scegliere Codex o Claude e il
nome del modello (vuoto eredita le impostazioni Modelli). Anche Correzione permette
di scegliere agente e modello: Codex rimane il predefinito, Claude usa la propria
configurazione e i propri controlli interattivi. Il rapporto del nodo fallito viene
passato al correttore scelto; il limite dei tentativi e i nuovi controlli restano
gli stessi. I workflow esistenti conservano le scelte salvate.
Il provider e i permessi vengono congelati all'avvio insieme al modello.

Il Piano deve produrre un unico rapporto finale `ORBIT_PLAN_REPORT` con UUID del
turno, `verdict` (`ready` o `blocked`), `summary` e `steps` non vuoti. Rapporti
mancanti, duplicati, malformati o con token errato fermano il flusso. Il Piano
valido viene mostrato nella sessione, prima di modificare file. Per impostazione
predefinita Orbit attende **Approva e implementa** oppure **Rifiuta piano**. Il
rifiuto termina il workflow senza avviare l'implementazione. La scelta viene
salvata nel journal prima del processo successivo; se il salvataggio fallisce,
nessun processo parte. Il Piano in attesa sopravvive alla chiusura dell'app e non
viene approvato automaticamente al riavvio. **Ferma** o **Ferma tutti** lo annullano.
Nell'editor puoi disattivare **Richiedi approvazione del Piano**: il passaggio
prosegue automaticamente. Questa scelta riguarda il Piano; i permessi sugli
strumenti restano gestiti dai controlli nativi di Codex e Claude.

Seleziona un nodo per modificare agente, modello, nome, limite di esecuzioni e
destinazioni. Per collegare i nodi, trascina l'uscita **Riuscito** (verde) o
**Fallito** (arancione) verso l'ingresso bianco o il corpo della card destinazione.
I collegamenti sono curve continue tra le porte, anche nei rami di ritorno,
senza percorsi rettangolari. La linea segue il puntatore e il nodo di arrivo
si evidenzia; il collegamento
viene salvato nella bozza solo al rilascio. Un rilascio nel vuoto o **Esc** annulla
il tentativo e conserva il collegamento precedente. Per scollegare usa il clic
destro sull'uscita oppure il pulsante **Scollega** nell'ispettore. Puoi anche
selezionare un'uscita e poi un ingresso con clic o tastiera, senza trascinare.
I nodi continuano a spostarsi trascinando il corpo della card, con coordinate
stabili anche quando il canvas scorre o cambia zoom. L'editor apre il grafo al
centro e mostra i dettagli nel pannello laterale. Puoi navigare trascinando lo
sfondo, scorrendo con due dita o attivando lo strumento Mano per trascinare anche
sopra le card. Il pinch del trackpad e **⌘ + rotella** zoommano sul puntatore;
la barra permette di scegliere una percentuale, usare **+ / −**, **Adatta tutto**
(**⌘0**), centrare il nodo selezionato e riordinare le card. La mini-mappa è
cliccabile per spostare la vista. Zoom e navigazione sono temporanei: non
modificano le coordinate salvate; **Riordina** cambia soltanto la posizione dei
nodi nella bozza e si conferma con **Salva workflow**. Il pannello laterale
raggruppa nome, limite di esecuzioni, collegamenti e configurazione dell'agente
in righe compatte; le spiegazioni del nodo si aprono da **Come funziona**.
In **Impostazioni → Workflow**, la raccolta permette di creare, duplicare,
rinominare nell'editor ed eliminare percorsi, e di scegliere il predefinito.
Il workflow precedente viene migrato senza cambiare nodi, collegamenti o modelli.
**Sessioni → Nuovo workflow** permette di scegliere un workflow salvato e
adattarlo soltanto per quel lavoro; le richieste a voce usano il predefinito.
Ogni sessione conserva una copia del grafo: modificare o eliminare un modello
salvato non cambia i lavori già avviati.

**Azioni** apre un catalogo con **Fasi standard** e **Azioni personalizzate**.
Il catalogo raggruppa le fasi standard in **Esplorazione e risultati** e
**Sviluppo e controllo**. Oltre a Piano, approvazione, implementazione, review,
verifica e correzione offre:

- **Ricerca**: raccoglie informazioni e confronta fonti.
- **Analisi**: valuta requisiti, alternative, dipendenze e rischi.
- **Test**: prepara o aggiorna test mirati e li esegue con gli strumenti consentiti.
- **Documentazione**: aggiorna istruzioni, esempi e limiti effettivi.
- **Sintesi**: riassume risultati, decisioni, evidenze e questioni aperte.

Queste cinque fasi hanno istruzioni iniziali modificabili, scelta di Codex o
Claude e modello, risultato precedente, ripetizioni e uscite Riuscito/Fallito.
Possono anche essere salvate come azioni riutilizzabili. Usano il rapporto
`ORBIT_ACTION_REPORT` come le azioni AI personali. I permessi restano quelli
configurati per l'agente; le istruzioni iniziali di Ricerca, Analisi e Sintesi
chiedono di non modificare file. **Test** è una fase svolta dall'agente, mentre
**Verifica** esegue direttamente il comando fisso e controlla il codice di uscita.

Puoi aggiungere una fase assente oppure configurare il nodo presente.
Ogni fase è opzionale nei percorsi liberi; Approva piano richiede un Piano valido.
Le azioni personalizzate sono **Azione AI** (istruzioni, agente e modello) oppure
**Comando shell**. **Salva come azione** nel pannello del nodo crea una copia
riutilizzabile nella raccolta **Le tue azioni**, senza collegamenti al vecchio
grafo. Ogni inserimento usa un nuovo identificatore. Rimuovere un'azione dal
catalogo non elimina i nodi già inseriti nei workflow.

Un'azione AI usa una sessione dell'agente scelto con istruzioni, richiesta,
risultato del nodo precedente e Piano soltanto se presente. Orbit richiede un rapporto strutturato
`ORBIT_ACTION_REPORT`, legato al turno corrente, con esito `passed`, `failed`
o `blocked`. Solo `failed` segue l'uscita Fallito; rapporti mancanti, ambigui,
scaduti, blocchi, errori della CLI e permessi negati fermano il lavoro.
L'azione può modificare file: invalida gli esiti precedenti di review e verifica,
che nel modello Sviluppo controllato devono essere eseguite nuovamente. Nei percorsi liberi i controlli sono opzionali. I cicli rispettano i limiti dei nodi.

**Aggiungi** inserisce un'azione dopo il nodo selezionato nei percorsi liberi,
oppure dopo l'implementazione nel modello Sviluppo controllato. Il primo nodo
aggiunto a un workflow vuoto diventa l'inizio. **Ripetizioni** ripete un'Azione AI
o un Comando shell sul successo, poi segue il collegamento: ad esempio una
ricerca di tre passaggi può usare un solo nodo con Ripetizioni 3. Il limite
**Esecuzioni** conta tutte le visite, comprese ripetizioni e ritorni dagli altri
nodi. Collegare Fallito al nodo stesso consente tentativi condizionali; collegare
Riuscito al nodo stesso crea un ciclo che termina al limite con esito fallito.
Per terminare normalmente dopo N successi usa Ripetizioni N e lascia l'uscita
Riuscito scollegata. I nodi Comando e Verifica
usano `/bin/zsh -c` nella cartella del progetto, con stdout/stderr, codice di uscita
reale e timeout di cinque minuti. Un comando può modificare file: invalida gli
esiti precedenti di review e verifica e nel modello Sviluppo controllato richiede
nuovi controlli prima del completamento. Il comando di verifica scelto all'avvio
rimane invariato. **Nuovo workflow** chiede quel comando solo se è presente un
nodo Verifica; un percorso di soli comandi non richiede CLI AI. **Generale · senza
progetto** usa la normale cartella Generale di Orbit, anche se non ci sono
progetti registrati.

L'uscita Fallito è configurabile per review con rilievi concreti e comandi usciti
con codice da 1 a 125. Autenticazione, permessi negati, errore del modello,
review/Piano bloccati o non validi, timeout, annullamento, uscite 126/127 e segnali
fermano il workflow. Nel modello Sviluppo controllato il runtime impedisce di
implementare senza Piano approvato, verificare senza review superata o dichiarare
completato un percorso privo di review e verifica valide, anche con collegamenti
errati. Nei percorsi liberi esegue soltanto i nodi scelti; se un Piano viene
generato con approvazione manuale, attende comunque la decisione dell'utente
prima di continuare. Non è un motore n8n
completo: i tipi disponibili sono quelli elencati, senza plugin di automazione,
webhook, esecuzioni parallele o connettori aggiuntivi.

Ogni nodo ammette da 1 a 10 esecuzioni (correzioni massimo 3, predefinite 2),
con limite complessivo di 64 passaggi e 20 nodi. Raggiungere un limite termina il
flusso con un messaggio esplicito. Ogni collegamento, contatore e nuovo turno è
salvato prima del relativo effetto esterno. Nessun turno incerto viene rilanciato
al riavvio. Il backend di sviluppo conserva steering e approvazioni interattive;
le correzioni e le review partono in contesti nuovi, senza riutilizzare grants.

`WorkflowGraphTests` copre approvazione/rifiuto, rapporti invalidi, modelli distinti,
recupero e salvataggio fallito, rami di correzione, cicli comando con vere uscite,
budget ed impossibilità di saltare la review nel modello Sviluppo controllato.
Copre inoltre ricerca con entrambi gli agenti, ripetizioni finite, cicli sul
fallimento, comandi senza CLI AI, verifica autonoma e approvazione di un Piano
opzionale, agenti misti per la correzione, modelli congelati, nuove fasi AI in
sequenza e Test → correzione Claude → Test senza fasi obbligatorie. I test nativi coprono entrambi i
protocolli anche dopo l'approvazione del Piano. Render UI:

```sh
ORBIT_GRAPH_PREVIEW_DIR=/tmp/orbit-graph-preview swift test --filter WorkflowGraphTests
```

Prova facoltativa con il login Codex esistente, in una cartella dimostrativa con
baseline Git e test invariati (Piano reale → attesa → approvazione da test →
implementazione nativa reale → review reale → unittest):

```sh
ORBIT_GRAPH_LIVE_DIR=/tmp/orbit-graph-live swift test --filter WorkflowLiveGraphTests
```

## Workflow implementazione → review → verifica

Questa sezione descrive i workflow storici e i chiamanti senza definizione a nodi.


In **Impostazioni → Sessioni → Nuovo workflow** scegli progetto, agente di
implementazione, revisore, richiesta e comando di verifica. Il comando va scelto
per quel progetto: ad esempio `swift test`, `npm test` oppure una sequenza di
controlli che restituisca un codice diverso da zero quando fallisce. Non viene
inventato dall'interprete. Per un progetto Swift il modulo propone `swift test`;
il valore viene salvato nel registro dopo un avvio riuscito.

Le tre richieste, il comando e le configurazioni vengono salvati insieme prima
del primo avvio. I modelli, provider e permessi fissati non cambiano quando modifichi
le impostazioni durante il lavoro. Una sola fase occupa il runtime della sessione.

1. **Implementazione:** usa l'agente scelto e i permessi del progetto. Solo un
   esito positivo del backend e un'uscita zero consentono la review.
2. **Review:** usa il revisore scelto in un contesto nuovo, senza `resume`, con la
   richiesta originale, il resoconto di implementazione e accesso ai file attuali.
   Codex usa `read-only`, approvazioni `never`, ignora la configurazione utente e
   disabilita app, plugin e ricerca web. Claude usa `plan`, solo `Read/Glob/Grep`,
   nessun MCP configurato e `disableAllHooks` per gli hook dell'utente/progetto;
   gli hook imposti da policy amministrative restano governati dalla CLI.
   La risposta deve terminare con un unico `ORBIT_REVIEW_REPORT` JSON contenente
   il token UUID del turno, `verdict`, `summary` e `findings` come array di stringhe.
   Solo `passed` senza findings abilita la verifica. `failed` con rilievi può
   avviare una correzione Codex, se abilitata. `blocked`, rapporto assente,
   duplicato, malformato o relativo a un altro turno fermano il workflow.
3. **Verifica:** `VerificationBackend` esegue il comando configurato con
   `/bin/zsh -c` nella cartella del progetto, con l'ambiente delle CLI di Orbit e
   i permessi dell'utente. Non usa un modello AI. Raccoglie stdout e stderr nel log
   e conserva gli ultimi 64.000 caratteri nel turno. L'uscita zero è necessaria;
   timeout (5 minuti), annullamento ed errori impediscono il successo del workflow,
   anche se il comando intercetta il segnale e termina con zero.

La scheda mostra stato, comando e risultato espandibile delle tre fasi del
**tentativo corrente**. **Tentativi precedenti** conserva fasi, output e fallimenti
precedenti senza mescolarli con i risultati del tentativo nuovo.

### Correzioni automatiche con Codex

Nel flusso a tre fasi con implementazione Codex, il parametro offre **Correzioni
automatiche Codex**: disattivate oppure massimo 1, 2 o 3. Il valore predefinito è
**2 correzioni**, oltre al tentativo iniziale. Il percorso vocale ora usa il grafo salvato nelle impostazioni.
I workflow salvati prima di questa funzione e quelli con implementazione Claude
Code mantengono l'arresto al primo fallimento.

Una review `failed` con rilievi concreti oppure un comando di verifica terminato
con un codice da 1 a 125 avvia la correzione, se resta budget. Il turno Codex riceve
la richiesta originale, i rilievi o l'output del comando (massimo 16.000 caratteri)
e il comando di verifica invariato. Usa configurazione, modello e permessi
fissati all'avvio e un contesto nuovo. Le istruzioni vietano di indebolire,
eliminare o saltare i test o cambiare il comando per ottenere un falso successo.
Questa istruzione aiuta il modello; la review indipendente resta necessaria.

Ogni correzione è seguita da una **nuova review in sola lettura**, con un nuovo
UUID e i rilievi precedenti, e dalla **stessa verifica reale** solo dopo una review
superata. Le vecchie fasi non avviate vengono annullate e i fallimenti rimangono
nella cronologia. Il contatore e le tre nuove richieste vengono salvati insieme
nel journal prima di avviare Codex. Una review superata di un altro tentativo
non può sbloccare la verifica corrente.

Approvazioni, **Reindirizza** e **Ferma** restano disponibili durante la correzione
interattiva. Nessuna approvazione del turno precedente viene trasferita. **Ferma**
annulla anche le fasi successive e non avvia un altro tentativo.

Orbit si arresta quando esaurisce le correzioni, se l'implementazione fallisce,
la review è bloccata o non valida, oppure davanti a errori della CLI, timeout,
annullamento o uscite 126/127 e segnali del comando. Un comando che restituisce 1
per un problema esterno può comunque consumare il budget: Orbit non può dedurre
con certezza la causa dal solo codice di uscita. I modelli utilizzano gli accessi
e i limiti delle CLI esistenti; non serve una nuova chiave API per questo ciclo.

Puoi chiedere esplicitamente un workflow anche a voce per un progetto con comando
già salvato. Il percorso vocale usa i nodi e i modelli salvati in Impostazioni → Workflow. Le richieste normali continuano a usare una singola
sessione: il workflow richiede un avvio esplicito. L'interprete non ha un'azione
che scavalchi la review o inventi il comando di verifica.

Lo steering è consentito nell'implementazione interattiva, aggiorna la richiesta su cui
si baserà la review e lascia attivi tutti i controlli. Review e verifica non
accettano reindirizzamento. Un seguito ordinario in un workflow viene rifiutato:
usa Reindirizza oppure avvia un nuovo workflow.

Al riavvio non parte alcuna fase automaticamente. Un'implementazione interrotta
non abilita la review; una review interrotta non abilita la verifica. Una fase già
superata e registrata può consentire la ripresa esplicita della fase successiva.
Il runtime non adotta eventuali subprocess superstiti e non ripete i turni incerti.
Una correzione già pianificata e salvata, ma non avviata, resta riprendibile
esplicitamente senza incrementare il contatore. Una correzione interrotta non
consente di saltare direttamente alla review.

`WorkflowIntegrationTests` verifica le transizioni positive, configurazioni
congelate, nuovo contesto e argomenti di review, rapporti negativi e non validi,
uscita reale del comando, annullamento, timeout e recupero. I test nativi
verificano steering con permessi pendenti, seguiti preservati, chiusura non
confermata e peer che ignora cancel. Usano CLI e peer locali simulati; non
costituiscono una prova end-to-end con provider AI reali.

Per esportare le nuove schermate con dati fittizi:

```sh
ORBIT_WORKFLOW_PREVIEW_DIR=/tmp/orbit-workflow-preview swift test --filter WorkflowIntegrationTests/testWorkflowPanelPreviews
```

`WorkflowIntegrationTests` copre anche correzioni dopo review e verifica,
limite esaurito, configurazioni congelate, journal prima dell'avvio, recupero e
arresto davanti a errori non correggibili automaticamente. I test del protocollo
nativo controllano approvazioni, annullamento e steering dentro una correzione.

Per provare i cicli con il login Codex reale, in cartelle di test isolate:

```sh
ORBIT_REPAIR_LIVE_DIR=/tmp/orbit-codex-repair-live swift test --filter WorkflowLiveRepairTests
```

La prova prepara una funzione intenzionalmente errata con un commit Git locale
di riferimento, per verificare che i test restino invariati, e usa due ingressi: review
reale della fixture errata, oppure verifica reale preceduta da una review simulata.
La correzione Codex, la review successiva e i test finali usano il runtime reale;
`result.json` e il journal conservano l'evidenza. Il test controlla che i test del
progetto restino invariati. Non afferma che l'implementazione iniziale della
fixture sia stata generata da un provider reale.

## Quote account nella finestra principale

Il footer resta visibile in ogni sezione, fuori dall’area scorrevole. Mostra la
percentuale rimasta per ciascuna finestra pubblicata dal provider e il prossimo
ripristino; cliccando Codex o Claude si vedono percentuale usata, dettagli e ora
del rilevamento. La lettura è senza inferenza: aggiornamento all’apertura, ogni
5 minuti mentre la finestra è aperta e tramite il pulsante Aggiorna.

Codex usa una connessione temporanea `app-server` e `account/rateLimits/read`,
senza creare thread o turni. La vista per `rateLimitsByLimitId` prevale sul
formato storico. Non si presume che il limite primario sia sempre di 5 ore.
Claude riusa in memoria il login della CLI per GET `/api/oauth/usage`, tramite
l’interfaccia usata dalla CLI installata; questo endpoint può cambiare tra
versioni. Richiede il permesso OAuth `user:profile`: un token con solo
`user:inference` continua a funzionare per gli agenti, ma non può leggere le
quote. Il pannello spiega come eseguire `claude auth login` per concederlo.
Orbit non rinnova, copia o modifica le credenziali; lettura dal Portachiavi senza
richiedere finestre di autenticazione, HTTP senza cache o redirect, errori
sanificati. Nessuna chiave nuova è richiesta. Le quote sono condivise con gli
altri utilizzi dell’account, non calcolate dal numero di token dei lavori Orbit.

Quote mancanti, errori o dati più vecchi di 10 minuti (oppure con ripristino già
passato) non diventano automaticamente 100% disponibile. Un vecchio rilevamento
può essere consultato nei dettagli, chiaramente indicato come tale.

## Loop fino a uno score

Nell’editor, **Modelli di partenza → Loop fino allo score** crea un percorso
libero con Attività → Valutazione score; sotto soglia la valutazione torna
all’attività. In alternativa si aggiunge **Valutazione score** dal catalogo.
Il nodo configura agente, modello, criterio e obiettivo da 0 a 100 (default 90).
I due nodi del modello hanno al massimo 5 esecuzioni ciascuno; il limite è
modificabile da 1 a 10 per nodo e resta il budget globale di 64 passaggi.

La valutazione parte in un contesto nuovo e in sola lettura. Richiede un unico
`ORBIT_SCORE_REPORT` terminale, legato al UUID del turno, con punteggio numerico
finito da 0 a 100 e motivazione. **Orbit**, non il verdetto dell’agente, confronta
il punteggio con la soglia. Il verde prosegue o conclude, l’arancione segue il
collegamento configurato; senza collegamento il risultato sotto soglia fallisce.
La successiva azione AI riceve la valutazione precedente come evidenza, con i
rilievi utili a migliorare il risultato. Il modello non deve gonfiare lo score
per raggiungere la soglia né modificare il criterio.

Rapporti mancanti, duplicati, scaduti, fuori intervallo o bloccati fermano il
workflow senza ulteriori tentativi. Esaurire il budget non equivale al successo.
Punteggi, soglia e motivazioni sono salvati nel journal con il risultato prima
che parta il nodo successivo e sono consultabili nella sessione. Lo score è il
giudizio del modello secondo il criterio, non sostituisce una verifica tramite
test. Nel modello Sviluppo controllato restano obbligatorie review e verifica.

`WorkflowScoreTests`, `WorkflowGraphTests` e `AgentUsageTests` coprono parser,
cicli, limiti, feedback, modelli indipendenti, persistenza e quote senza inferenza
con fixture locali. `ORBIT_LIVE_QUOTA=1 swift test --filter AgentUsageTests.testLiveReadOnlyAccountQuota`
interroga solo le quote reali; non usa il modello. Per i render UI normali e
Riduci movimento: `ORBIT_USAGE_PREVIEW_DIR=/tmp/orbit-usage-preview swift test --filter AgentUsageTests.testOptionalMainWindowAndScoreUI`.
