# Contribuire a Orbit

Apri un’issue descrivendo cosa vuoi ottenere, oppure una pull request con un cambiamento concreto e le verifiche eseguite. Puoi usare italiano o inglese.

Per lavorare sul progetto servono macOS 15+, una toolchain Swift 6 e gli SDK macOS. Usa `swift build` e `swift test`. I test ordinari non richiedono account AI, chiavi Fish o microfono: usano processi e servizi simulati. Il test reale è facoltativo e si abilita con `ORBIT_LIVE_TESTS=1`.

Mantieni separati dominio e servizi (`OrbitCore`) dalle finestre, dall’audio e dal rendering (`OrbitDesktop`). Ogni nuova azione deve verificare il destinatario prima di raggiungere il CLI. Evita di cambiare progetto, modello o ID CLI di una sessione già avviata.

Per il lavoro sulle finestre verifica anche tastiera, più monitor, Riduci movimento, chiusura e riapertura delle impostazioni. La sezione Sessioni e il pannello flottante devono offrire gli stessi dati senza sovrapporsi quando la finestra principale è aperta.

Non aggiungere credenziali, preferenze personali, percorsi utente reali, log delle repository o audio di voci di terzi. Le schermate per il README si generano con `swift run Orbit --render-docs docs/images` e dati dimostrativi.

Il codice e la documentazione sono MIT; la mascotte ha la licenza indicata in NOTICE.md. Inviando un contributo, assicurati di avere il diritto di distribuirlo con la licenza applicabile al file.
