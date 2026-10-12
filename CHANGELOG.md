# Novità di Orbit

## 1.5.0 — 12 ottobre 2026

Questa release pubblica l’implementazione con workflow nativi e allinea GitHub
all’app attualmente installata sul Mac di sviluppo.

### Workflow configurabili

- Raccolta di workflow indipendenti: creazione, duplicazione, eliminazione e
  selezione del predefinito.
- Editor visuale con trascinamento dei nodi, connessioni tra porte, zoom,
  spostamento della vista, centratura, minimappa e pannello compatto dei dettagli.
- Percorsi liberi, anche senza Piano o implementazione, e modello Sviluppo
  controllato con Piano, approvazione, implementazione, review e verifica.
- Agente e modello configurabili per nodo AI, compresa Correzione.
- Fasi Ricerca, Analisi, Test, Documentazione, Sintesi e Valutazione score.
- Azioni AI e shell personali, istruzioni modificabili, catalogo riutilizzabile
  e ripetizioni sul successo.

### Esecuzione e controlli

- Approvazione manuale del Piano di default, disattivabile nell’editor.
- Review e valutazioni in contesti nuovi e in sola lettura; verifica mediante
  comando e codice di uscita reale.
- Cicli automatici di correzione dopo review o verifica fallite, con Codex o Claude.
- Loop fino a uno score da 0 a 100: criterio, soglia, agenti e limiti configurabili;
  feedback tra tentativi e cronologia dei punteggi nella sessione.
- Limiti per nodo, fino a 3 Correzioni e budget globale di 64 passaggi. Nessun
  successo implicito su rapporti non validi, blocchi o tentativi esauriti.
- Controlli interattivi nativi Codex app-server e Claude Code: richieste di
  permesso transitorie, steering con interruzione confermata e ripresa del contesto.
- Journal persistente di turni, code, decisioni e risultati; recupero senza
  ripetere automaticamente turni avviati o autorizzazioni scadute.
- Integrazione esterna DeepSeek Harness rimossa; compatibilità di lettura dei
  dati storici senza convertirli in contesti Codex o Claude.

### Utilizzo e documentazione

- Footer fisso con quota residua, finestre disponibili e ripristino di Codex e Claude.
- Aggiornamento all’apertura, ogni 5 minuti e manuale; lettura senza inferenza.
- Dati mancanti o scaduti segnalati senza stime. Per Claude le quote richiedono
  il permesso OAuth di lettura del profilo, distinto dall’uso del modello.
- README, guida dei workflow e immagini renderizzate da SwiftUI con dati fittizi.

### Distribuzione e prove

- Versione app 1.5.0, build 15000. Pacchetto Apple Silicon per macOS 15+,
  con firma ad-hoc, non notarizzato; sorgente disponibile per la compilazione locale.
- La precedente implementazione 1.4 resta nel branch `archive/orbit-1.4` e nella
  cronologia. I due formati dati sono distinti; nessuna migrazione automatica
  da `Application Support/Orbit` a `Application Support/Jarvis`.
- Test automatici del runtime, protocolli simulati, workflow, parser, persistenza,
  limiti, score e UI. Le prove con provider reali sono facoltative: i test simulati
  non attestano una riuscita end-to-end su ogni modello o account.
- La lettura delle quote Codex è stata verificata sull’account reale; accesso alle
  quote Claude con soli permessi di inferenza correttamente segnalato.

[Guida illustrata](docs/workflows.md) · [Dettagli del runtime](docs/agent-runtime.md)
