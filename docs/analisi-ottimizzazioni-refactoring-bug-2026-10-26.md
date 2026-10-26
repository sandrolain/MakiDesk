# Analisi di ottimizzazioni, refactoring e bug

Data: 26 ottobre 2026. Revisione analizzata: `36e5f078b88b966d2d415a0b24529bc52f4cbfdf` (`main`).

## Perimetro e metodo

Analisi statica del codice Swift e dei test esistenti, con approfondimento dei flussi AX, animazione finestre, note e persistenza, catture, libreria screenshot, Dropzone ed esecuzione processi. Nessuna modifica applicativa, build, esecuzione di test o prova sul desktop. Le verifiche suggerite sotto sono attività future: non vanno interpretate come test superati o bug riprodotti in esecuzione.

Il repository era pulito all'inizio. `AGENTS.md` richiama due analisi del 21 ottobre, ma i file `docs/analisi-performance-residua-2026-10-21.md` e `docs/analisi-performance-bug-2026-10-21.md` sono assenti in questa revisione. Non è stato possibile consultarne il ledger; i riferimenti N13/N15/N17 sono stati confrontati direttamente con il codice.

Le evidenze sono divise in **difetti individuati nel flusso del codice**, **limiti prestazionali confermati dalla struttura** e **opportunità di refactoring**. Una race identificata staticamente richiede comunque un test controllato per dimostrarne la manifestazione e verificare la correzione. Non sono state misurate latenze, CPU o memoria residenti. L'analisi non pretende di esaurire tutti i percorsi delle circa 26.000 righe Swift applicative.

Priorità: **P1** per consenso all'esecuzione, perdita di coerenza dei dati o processi lasciati attivi; **P2** per comportamento errato circoscritto e reattività; **P3** per manutenzione e ottimizzazioni da profilare. La priorità esprime l'ordine proposto, non la frequenza osservata.

## Risultati e ordine consigliato

| ID | Priorità | Risultato | Tipo | Impegno indicativo |
| --- | --- | --- | --- | --- |
| A01 | P1 | Conferma Dropzone non vincolata al comando approvato | Difetto di validazione | Medio |
| A02 | P1 | Reset note vulnerabile alla pubblicazione di un vecchio caricamento | Difetto asincrono | Medio |
| A03 | P1 | Escalation SIGKILL subordinata alla vita del solo processo principale | Difetto di teardown | Medio/alto |
| A04 | P2 | Esclusione reciproca Dropzone acquisita dopo un `await` | Difetto di reentrancy | Basso/medio |
| A05 | P2 | Cancellazione Dropzone durante la preparazione non persistita | Difetto di cancellazione | Medio |
| A06 | P2 | Miniature screenshot non aggiornate quando cambia il file allo stesso percorso | Difetto di invalidazione | Basso |
| A07 | P2 | Scansioni screenshot concorrenti senza coalescing né invalidazione alla chiusura | Limite di scheduling | Medio |
| A08 | P2 | Scritture AX delle animazioni ancora nel run loop principale | Limite prestazionale, N13 | Alto |
| A09 | P2 | Primo accesso ai formati immagine Shelf ancora sincrono | Limite prestazionale, N15 | Medio/alto |
| A10 | P2 | Callback dei salvataggi esterni note con controlli di validità incompleti | Rischio di incoerenza | Medio |
| A11 | P2 | Errori di persistenza note conservati ma non comunicati adeguatamente | Difetto di osservabilità | Medio |
| A12 | P3 | Ripristino note carica tutti i corpi, sebbene fuori dal main actor | Limite di scala, N17 | Alto |
| A13 | P3 | Libreria screenshot ripete trasformazioni e conversioni immagini | Ottimizzazione da misurare | Medio |
| R01 | P3 | Separare orchestration, I/O e presentazione nei file maggiori | Refactoring | Incrementale |
| R02 | P3 | Esplicitare proprietà concorrente e confini UI/worker | Refactoring | Incrementale |
| R03 | P3 | Riparare i riferimenti alle analisi mancanti | Documentazione | Basso |

## Difetti e interventi

### A01 — La conferma deve identificare esattamente il comando

**Evidenza:** [ShelfController.swift](../Sources/MakiDesk/ShelfController.swift), `runDropzone`, circa righe 1572–1599; [DropzoneCoordinator.swift](../Sources/MakiDesk/DropzoneCoordinator.swift), `confirm` e `run`, righe 326–377; [DropzoneConfig.swift](../Sources/MakiDesk/DropzoneConfig.swift), `requiresConfirmation` e `markConfirmed`, righe 224–230.

Il pannello mostra una configurazione `pending`, poi chiama `confirm(zoneID:)` e ripete `run(... confirmed: true)`. `run` rilegge il file, ma il booleano permette di superare `zone.requiresConfirmation` anche quando il contenuto del comando è cambiato rispetto a quello mostrato. Un caso concreto è una modifica esterna del JSON mentre il dialogo è aperto. La conferma di sovrascrittura presenta lo stesso problema: `confirmedOverwrite: true` non identifica il percorso precedentemente mostrato.

**Intervento:** trasferire una conferma contenente ID zona e hash della configurazione eseguibile approvata; per l'overwrite includere il percorso risolto. Dopo ogni rilettura, confrontare i valori e chiedere una nuova conferma se differiscono. `confirm` deve verificare la versione approvata prima di salvarla, evitando di riscrivere una configurazione più recente con lo snapshot precedente.

**Verifica proposta:** sospendere dopo `.needsConfirmation`, sostituire il comando nello store isolato e riprendere con la conferma precedente; il nuovo comando non deve partire. Ripetere cambiando l'output dichiarato fra richiesta e conferma di overwrite.

### A02 — Reset note durante il caricamento iniziale

**Evidenza:** [NotesStore.swift](../Sources/MakiDesk/NotesStore.swift), `loadIfNeededAsync` righe 169–190, `apply` righe 237–270 e `deleteAllNotes` righe 660–687. Chiamante del reset: [WorkspaceStore.swift](../Sources/MakiDesk/WorkspaceStore.swift), circa riga 611.

Il caricamento legge uno snapshot sulla coda I/O e ne programma l'applicazione sul main actor. `deleteAllNotes()` non invalida quello snapshot. Se il caricamento è in corso, `loadIfNeeded()` ritorna immediatamente; il reset attende la coda I/O con `sync`, cancella i file e svuota il modello, ma la callback già accodata può successivamente eseguire `apply(snapshot)` e reinserire le vecchie note. Una scrittura successiva può anche ripersistirle. Inoltre il reset esegue attesa e cancellazioni sul main actor.

**Intervento:** introdurre un'epoca di ripristino/reset controllata alla pubblicazione; serializzare il reset sulla coda I/O, definendo come terminano i callback del caricamento invalidato. Dopo il reset nessun risultato precedente deve ricreare note o sessione. Tenere distinti caricamento completato e inventario temporaneamente vuoto.

**Verifica proposta:** lettore iniettato che restituisce lo snapshot solo dopo l'avvio del reset; verificare modello e directory vuoti anche dopo aver drenato le callback. Includere apertura/chiusura rapida del pannello e creazione di una nuova nota dopo il reset.

### A03 — Cancellazione del gruppo di processi incompleta

**Evidenza:** [CommandRunner.swift](../Sources/MakiDesk/CommandRunner.swift), attesa e `process.finish()` righe 83–115; `ProcessRun.terminate` righe 272–295. Test esistente: [CommandRunnerTests.swift](../Tests/MakiDeskTests/CommandRunnerTests.swift), `testCancelKillsTheWholeProcessGroup`.

`SIGTERM` viene correttamente inviato al gruppo. L'invio di `SIGKILL` dopo la grazia, però, dipende da `ProcessRun.running`, che diventa falso appena termina il processo principale seguito con `waitpid`. Se una shell termina e un discendente ignora `SIGTERM`, l'escalation viene saltata anche se quel discendente continua a lavorare. Il test attuale usa `sleep`, che non esercita il caso di un discendente resistente a TERM. La pulizia della directory può inoltre avvenire mentre il discendente la usa ancora.

**Intervento:** definire un ciclo di vita della terminazione del gruppo distinto da quello del leader e mantenere la proprietà del lavoro fino al completamento della pulizia. Progettare esplicitamente la protezione dal riuso di PID/PGID: inviare semplicemente un segnale ritardato senza controlli non è una correzione sufficiente.

**Verifica proposta:** processo controllato con leader che esce su TERM e figlio che lo ignora, mantenuto nel gruppo; verificare cessazione di entrambi e assenza di scritture dopo il completamento. Usare processi e directory di test isolati.

### A04 — Due avvii possono superare insieme il controllo della stessa zona

**Evidenza:** [DropzoneCoordinator.swift](../Sources/MakiDesk/DropzoneCoordinator.swift), `run`, righe 359–377.

Il controllo `runningZones.contains(zoneID)` precede `await DropzonePreparer.itemInfos(for:)`; l'inserimento nel set avviene dopo. Il coordinatore è `@MainActor`, ma l'isolamento non impedisce la reentrancy attraverso un `await`: due invocazioni possono superare il controllo prima che una riservi la zona. Entrambe possono avviare il comando e sovrascrivere `runIdentifiers[zoneID]`; il `defer` di una può rimuovere lo stato dell'altra.

**Intervento:** riservare la zona prima della prima sospensione e associare lo stato a un token di esecuzione. Rilasciarlo anche su rifiuto o richiesta di conferma; un completamento deve rimuovere solo il proprio token.

**Verifica proposta:** sospendere la prima chiamata nel lettore dei metadati e invocare la seconda; ottenere un solo avvio e uno stato coerente fino alla fine.

### A05 — Annullamento perso prima dello spawn

**Evidenza:** [DropzoneCoordinator.swift](../Sources/MakiDesk/DropzoneCoordinator.swift), `cancel` righe 337–340 e preparazione/avvio righe 375–393; [CommandRunner.swift](../Sources/MakiDesk/CommandRunner.swift), `cancel` e registrazione di `running`.

Il run ID viene registrato nel coordinatore prima di `await prepare`. Durante la preparazione, `cancel(zoneID:)` delega al runner, che non ha ancora un processo per quell'ID e ritorna. Il coordinatore non conserva l'intenzione di annullare: finita la preparazione, può comunque chiamare `runner.run`. Va inoltre definito il comportamento di un task già cancellato all'ingresso nel runner, che oggi prepara e genera il processo prima del cancellation handler.

**Intervento:** stato per run (`preparing`, `running`, `cancelling`, `finished`) o task posseduto dal coordinatore, cancellazione persistente e controllo subito prima dello spawn. Prevedere cleanup simmetrico anche se non è stato creato un processo.

**Verifica proposta:** fermare un preparatore iniettato, annullare e riprendere; nessuno spawn e directory temporanea rimossa. Ripetere con task già cancellato.

### A06 — Miniature obsolete per file aggiornati allo stesso path

**Evidenza:** [ScreenshotLibrary.swift](../Sources/MakiDesk/ScreenshotLibrary.swift), `ScreenshotFile.id`, `ScreenshotCard` e `.task(id: file.path)`, circa righe 8–16 e 770–797.

La scansione rileva la data di modifica, ma il task della miniatura è identificato soltanto dal percorso. Se un'immagine viene sovrascritta e la card mantiene identità e posizione, SwiftUI può aggiornare i metadati senza rilanciare il task: resta l'immagine precedente.

**Intervento:** chiave della richiesta con percorso e revisione del file, almeno data e dimensione, oppure revisione esplicita della scansione per i file modificati. Cancellare la richiesta precedente e controllare la chiave alla pubblicazione; definire il fallback per risoluzioni temporali insufficienti del filesystem.

**Verifica proposta:** sostituire un'immagine con contenuto diverso allo stesso percorso, mantenere la card montata e verificare il caricamento della nuova miniatura.

### A07 — Scansioni screenshot senza limite esplicito

**Evidenza:** [ScreenshotLibrary.swift](../Sources/MakiDesk/ScreenshotLibrary.swift), `refresh` righe 187–213, `hide` righe 136–141, watcher e debounce righe 328–359.

La generation impedisce di pubblicare una scansione superata da un'altra, ma ogni `refresh()` avvia un nuovo lavoro su una coda globale. Il debounce del watcher riduce gli ingressi ravvicinati, senza impedire scansioni sovrapposte se la cartella è lenta o altri chiamanti richiedono aggiornamenti. `hide()` ferma watcher e debounce, ma non invalida la scansione in corso, che può pubblicare a pannello chiuso.

**Intervento:** una scansione attiva e un solo refresh pendente, sessione visibile esplicita e controllo di generation/cartella/sessione alla pubblicazione. Una file operation avviata dall'utente può terminare dopo la chiusura, ma il suo completamento deve rispettare la sessione UI e la cartella corrente.

**Verifica proposta:** simulare molte richieste con scanner lento; massimo un lavoro attivo e un seguito. Chiudere o cambiare cartella prima della risposta e verificare che non pubblichi risultati obsoleti.

### A08 — Animazioni AX sul thread principale: N13 ancora aperto

**Evidenza:** [WorkspaceStore.swift](../Sources/MakiDesk/WorkspaceStore.swift), `animateFrame` righe 1203–1256; primitive in [WindowController.swift](../Sources/MakiDesk/WindowController.swift), righe 526–548 e 679–697.

Il timer a 60 Hz effettua direttamente le scritture cross-process di posizione e dimensione. Esistono già mitigazioni utili: salta valori ripetuti, termina su errore, rispetta Reduce Motion e interrompe l'animazione se una scrittura supera circa 33 ms. Queste riducono il lavoro successivo, ma non eliminano il blocco già subito dal run loop. Con più finestre il lavoro può sommarsi.

**Intervento:** executor dedicato con serializzazione per identità, sostituzione del frame intermedio pendente e generation del comando. Pubblicare esiti e geometria confermata sul proprietario UI; mantenere ordine posizione/dimensione, gestione rifiuti e verifica finale. Prima di spostare le chiamate, tracciare tutti i chiamanti delle primitive per impedire scritture concorrenti sullo stesso target.

**Verifica proposta:** provider AX controllabile per errori e lentezza, poi misure release separate per handler, coda, I/O AX, primo movimento e completamento. Confrontare comandi ripetuti, layout multifinestra e Reduce Motion. Non è stimato un guadagno percentuale.

### A09 — Shelf: rappresentazioni promesse, ma richiesta ancora bloccante

**Evidenza:** [ShelfImageWriter.swift](../Sources/MakiDesk/ShelfImageWriter.swift), `prepare` e `data(for:)`, righe 25–47; [ShelfController.swift](../Sources/MakiDesk/ShelfController.swift), circa riga 674.

La preparazione PNG viene già avviata fuori dal percorso iniziale del drag. Tuttavia `pasteboardPropertyList` chiama sincronicamente `data(for:)`: una richiesta TIFF non preparata, un cache miss o un'immagine oltre la soglia di cache di 8 MiB richiedono encoding al momento della richiesta. Il lock può anche attendere l'encoding PNG già in corso. La coda seriale di preparazione non ha un limite applicativo ai job accodati.

**Intervento:** budget di preparazione con priorità agli elementi realmente trascinati e rimozione del lavoro non più utile; valutare rappresentazioni già pronte o trasferimento tramite file promise dove compatibile con le destinazioni. Il protocollo sincrono non diventa asincrono sostituendo soltanto la coda. Documentare il compromesso tra memoria, preparazione e latenza della prima richiesta.

**Verifica proposta:** richiedere PNG e TIFF con cache calda/fredda e immagini oltre soglia; misurare attesa sul lock, encoding e memoria. Non dichiarare N15 risolto prima di queste prove.

### A10 — Salvataggi esterni note: serve una generation dell'associazione

**Evidenza:** [NotesStore.swift](../Sources/MakiDesk/NotesStore.swift), `saveToExternalAsync` righe 491–538 e `saveAsAsync` righe 556–591. Confronto utile: `refreshExternalState` controlla anche URL e baseline alla pubblicazione.

Le callback dei salvataggi verificano l'esistenza della nota e usano `draftRevision` per pulire il dirty state. L'aggiornamento di `externalBaseline` e, in Save As, `externalURL`, avviene però senza controllare una revisione dell'associazione. Una risposta riferita al vecchio URL non dovrebbe aggiornare la baseline di un'associazione successiva. Anche la validità della scrittura su disco, non soltanto della callback, va definita quando più operazioni sono in coda.

**Intervento:** distinguere revisione testo, revisione dell'associazione e ordine delle operazioni di salvataggio. Legare URL, baseline e completamento al token corretto; non rifiutare indiscriminatamente l'aggiornamento della baseline solo perché è cambiato il testo: la baseline deve descrivere ciò che è stato davvero scritto.

**Verifica proposta:** orchestrare salvataggio, modifica del testo, Save As e cambio associazione con worker controllabile. Questo è un rischio individuato staticamente: occorre verificare quali interleaving siano raggiungibili dai comandi UI attuali prima di quantificarne la frequenza.

### A11 — Errori note non sufficientemente visibili né ritentati

**Evidenza:** [NotesStore.swift](../Sources/MakiDesk/NotesStore.swift), `enqueueDraftSave` righe 727–744, `flushAsync` righe 781–804 e `scheduleSession` righe 818–831.

Il fallimento del draft mantiene correttamente `pendingDrafts`, ma non produce una segnalazione al chiamante. `flushAsync` scarta gli errori dei draft e della sessione; il completion non comunica l'esito. La scrittura differita della sessione usa `try?` senza uno stato di errore dedicato. Se l'utente non modifica più il testo e l'app termina in modo anomalo, il fatto che il draft sia rimasto dirty in RAM non garantisce recuperabilità.

**Intervento:** esito strutturato del flush, stato di salvataggio fallito visibile e retry limitato con backoff per errori recuperabili. Distinguere draft e sessione, evitando notifiche ripetute e conservando i dati sporchi. I log non devono esporre testi o percorsi.

**Verifica proposta:** writer iniettato che fallisce e poi riesce; controllare segnalazione, retry, revisioni e persistenza della sessione. Non rimuovere il fence sincrono di terminazione senza un protocollo equivalente.

### A12 — Ripristino completo dei testi: N17 ancora aperto

**Evidenza:** [NotesStore.swift](../Sources/MakiDesk/NotesStore.swift), `readSnapshot` righe 202–234 e `loadIfNeededAsync` righe 169–190.

Il percorso asincrono evita il caricamento sul main actor e rimanda la lettura delle baseline esterne, ma legge tutti i draft in memoria. Il costo cresce con i byte complessivi dell'archivio, anche quando viene aperta una sola nota. Esiste inoltre un percorso sincrono `loadIfNeeded()` usato da varie API: prima di eliminarlo vanno separati i chiamanti UI dai test e dagli usi intenzionali.

**Intervento:** misurare prima archivi realistici; se necessario separare catalogo/metadati e corpi caricati su richiesta. Ricerca, recupero crash e confronto con file esterni devono distinguere testo non caricato da testo vuoto. È un cambiamento architetturale, con necessità di compatibilità dei dati.

### A13 — Lavoro ripetuto nella libreria screenshot

**Evidenza:** [ScreenshotLibrary.swift](../Sources/MakiDesk/ScreenshotLibrary.swift), `visibleFiles` e `sections` righe 80–129; `thumbnailData` circa righe 839–855.

`visibleFiles` filtra e ordina, `sections` ricostruisce formatter e gruppi; sono proprietà calcolate sul main actor. La miniatura viene decodificata/ridotta sul worker, ricodificata in PNG e poi ricostruita come `NSImage` sul percorso UI. Ogni card crea un task detached senza un pool di concorrenza applicativo; la cancellazione del task SwiftUI non viene propagata esplicitamente al task detached. Il lavoro immagine è quindi ottimizzabile, ma il costo effettivo va profilato.

**Intervento:** risultati derivati invalidati solo da file/query/ordinamento/raggruppamento; tie-break stabile per date uguali; pipeline miniature con limite di concorrenza, cancellazione e budget in byte. Valutare trasferimento di un'immagine immutabile preparata sul worker per evitare il passaggio PNG, verificando proprietà concorrente e API AppKit. Evitare una cache globale aggiuntiva senza un proprietario e un budget definiti.

**Verifica proposta:** cartelle piccole e grandi, scroll rapido, cambio ordinamento, selezione multipla e chiusura durante il caricamento. Contare lavori, trasformazioni e byte delle immagini trattenute dalla UI, oltre agli eventuali byte in cache.

## Refactoring proposti

### R01 — Estrarre responsabilità con confini verificabili

`WorkspaceStore.swift` conta 3.051 righe, `WindowPalette.swift` 2.211, `ShelfController.swift` 2.106, `NotesPanel.swift` 1.434 e `ScreenshotLibrary.swift` 985. Le dimensioni sono un indicatore di navigabilità, non una dimostrazione di bug.

Le estrazioni più utili sono: ciclo di vita delle scritture animate dal WorkspaceStore; esecuzione e presentazione degli esiti Dropzone dalla Shelf; pipeline I/O/miniature dal file della libreria screenshot. Mantenere stato e identità sotto un proprietario esplicito, evitando singleton duplicati e separazioni puramente cosmetiche in extension. Procedere insieme alle correzioni pertinenti, senza una riscrittura generale.

### R02 — Proprietà concorrente esplicita

`WindowIndex` utilizza stato UI senza isolamento di tipo, worker per discovery/observer e lock per le metriche. `WindowPalette` e altre parti UI ricorrono a `MainActor.assumeIsolated`. Questo non dimostra da solo una race: è però più difficile garantire gli executor corretti e controllare i callback futuri.

Proporre un audit separato con build strict-concurrency per il progetto Swift 5.9, senza migrare implicitamente a Swift 6. Tipizzare i payload trasferiti ai worker, documentare i singoli `@unchecked Sendable` e attribuire alle classi UI l'isolamento appropriato. Conservare le sincronizzazioni motivate: ad esempio `ProcessRun` ha un lock dedicato ai propri flag. Non usare annotazioni ampie per sopprimere i warning.

### R03 — Riallineare la documentazione di manutenzione

Ripristinare le analisi storiche se devono essere mantenute oppure sostituire i riferimenti in `AGENTS.md` con documenti effettivamente versionati. Questo documento registra lo stato attuale, ma non ricostruisce né sostituisce il ledger mancante. Quando un intervento viene implementato, registrarvi separatamente modifica, verifica automatica ed eventuale misura sul desktop.

## Parti già ben impostate da preservare

- `WindowIndex.snapshot()` legge la cache senza discovery nascosta; il refresh asincrono unisce i chiamanti e usa una revisione prima di pubblicare. La riconciliazione riserva gli ID precedenti e conserva le finestre temporaneamente indisponibili.
- `WindowCapture` ha chiavi comprensive di identità e dimensione, cache limitata a 64 MiB e un batch successivo sostituibile. La palette controlla visibilità e generation nelle callback. Palette, Peek e scoring condividono un budget di cattura; il nuovo percorso `ScreenRegionCapture` effettua invece la propria cattura diretta, da includere nella valutazione complessiva dei picchi.
- Le note hanno una coda seriale per la persistenza e controlli di revisione sui draft; ricerca e caricamento principale del pannello sono già asincroni. Non riproporre come nuove correzioni questi interventi esistenti.
- Il selettore di regione separa geometria e overlay, invalida le richieste dello snapshot alla chiusura e usa `PanelFocusReturn`. Queste garanzie vanno conservate.
- Il runner usa un gruppo di processi, timeout ed estratti di output limitati. Il limite degli estratti riguarda la RAM: i log su disco non hanno nello stesso codice un tetto di dimensione, opportunità da valutare per comandi molto verbosi.

## Piano di lavoro e criteri di accettazione

1. **Consenso, dati e teardown:** A01–A03, ognuno con una modifica dedicata e test di regressione controllati. Nessuna prova sui dati reali dell'utente.
2. **Stato delle operazioni:** A04–A07 e A10–A11, introducendo solo le dipendenze iniettabili necessarie a governare gli interleaving.
3. **Reattività e risorse:** A08–A09 e A13 dopo misure release; A12 solo se la dimensione degli archivi ne giustifica il costo.
4. **Manutenzione:** R01–R03 in piccoli passi legati alle responsabilità toccate.

Per ciascuna correzione: un proprietario dell'operazione, un criterio di validità alla pubblicazione, teardown esplicito e un limite ai lavori pendenti. Aggiungere test pertinenti nella fase di implementazione, poi build e verifiche appropriate. Per AX/focus/display la suite non sostituisce una verifica manuale con app lente, release rapide dei tasti e monitor con origini e scale diverse.

Per dichiarazioni prestazionali future riportare ambiente, campioni, mediana/p95/massimo e stato delle cache. Separare il tempo tastiera→handler, attesa inventario, I/O AX, prima risposta visibile e animazione. I budget della cache non sono limiti alla memoria residente totale.

## Verifiche di questa consegna

Controllati stato Git iniziale, sorgenti e test citati. Per la stesura iniziale: controllo dei riferimenti locali e `git diff --check`. Nessuna build, test, lancio, modifica dei dati utente o benchmark era stato eseguito in quella fase.

## Ledger implementazione — 2026-10-26

Aggiornamento successivo all'analisi: le correzioni seguenti sono state implementate nel checkout e verificate con test automatici mirati. Questo ledger descrive lo stato del codice dopo le modifiche, senza sostituire le evidenze statiche sopra.

| Rilievo | Stato | Modifica e verifica |
| --- | --- | --- |
| A01 Dropzone: conferma obsoleta e overwrite | Corretto | Conferma vincolata all'hash del comando corrente; autorizzazione overwrite vincolata al path esatto. Test su comando modificato e path. |
| A02 reset note durante restore | Corretto | Generation invalida il caricamento precedente; reset e cancellazione persistiti in coda senza bloccare il main thread. Test con restore in volo. |
| A03 processi discendenti | Corretto | L'escalation termina il gruppo anche quando il leader esce dopo TERM. Test con processo figlio che ignora TERM. |
| A04–A05 prenotazione e cancellazione Dropzone | Corretto | Prenotazione prima del primo await e token cooperativo attraverso preparazione/runner. Test di cancellazione durante preparazione e prevenzione spawn. |
| A06–A07 libreria screenshot | Corretto | Revisione miniatura basata su path/mtime/dimensione; refresh limitato a un lavoro più un follow-up, ignorando callback di sessioni chiuse. Test di coalescing e invalidazione. |
| A08 animazioni AX (N13) | Mitigazione implementata | Scritture per finestra serializzate e intermedie accorpate; chiamate AX e verifica finale fuori dal main thread. Test con writer controllato per ordine e concorrenza. Mancano misure su desktop reale e verifica manuale con app lente/display multipli. |
| Regressione resize/trasferimento Edge | Parziale | La diagnosi ha rilevato il minimo AX Edge di 405 px su target verticali inferiori. Il trasferimento fra display ora conserva la dimensione corrente quando entra nel display e abilita la verifica con retry, evitando il resize sotto il minimo durante lo spostamento. Test geometrico mirato. La prova GUI precedente era contaminata da una seconda istanza MakiDesk avviata dall'agente, ora terminata; serve ripetere la verifica manuale con una sola istanza. |
| A09 trasferimento immagini Shelf (N15) | Mitigato | PNG/TIFF sono preparati all'ammissione; cache LRU forte limitata a 288 MiB e 200 rappresentazioni evita il ricalcolo dopo normale pressione di memoria. Se un output eccede il limite o viene espulso dopo il budget, il callback può ancora codificare sincronicamente. |
| A10 associazione file note | Corretto | Token dell'associazione invalidato da nuove operazioni, reset ed eliminazione; pubblicazione legata a revisione/URL. Test con Save As concorrenti. |
| A11 errori di persistenza note | Corretto con retry limitato | Errori di scrittura esposti nell'interfaccia e dirty state preservato; retry automatico con backoff esponenziale limitato a 60 secondi. Test del fallimento di scrittura eseguito; il retry usa il flush serializzato esistente. |
| A12 ripristino note (N17) | Implementato nei percorsi UI asincroni | Il restore asincrono ora carica metadati e anteprima titolo; il corpo si carica quando la nota è selezionata. La ricerca legge i corpi sul worker senza trattenerli. Restano i percorsi sincroni interni, mantenuti per le API/test sincroni. |
| A13 decodifica miniature screenshot | Mitigazione implementata | Rimossa la conversione immagine→PNG→NSImage; decodifica CGImage diretta e massimo tre decodifiche simultanee. Nessun benchmark prestazionale eseguito. |
| R01 | Parziale | `AXFrameWriteCoordinator` è stato estratto da `WindowController.swift` in un file dedicato. Restano estrazioni mirate dai file più grandi. |
| R02 | Parziale | Classi UI per HUD, MiniMap, Peek, drag, outline, palette e WorkspaceStore hanno isolamento MainActor; callback note sono esplicitamente MainActor/Sendable; i callback timer/notification toccati saltano sul main actor. L'audit strict-concurrency trova ancora warning, soprattutto in `WindowIndex` e `WorkspaceStore`; non sono stati silenziati con `@unchecked Sendable`. |
| R03 | Corretto | `AGENTS.md` ora collega questo documento versionato; i due riferimenti storici del 21 ottobre non erano presenti in checkout. |

### Verifiche dopo le correzioni

Test mirati: `DropzoneCoordinatorTests` (14), `NotesStoreTests` (24, inclusi caricamento lazy e retry), `CommandRunnerTests` (13), `ScreenshotLibraryTests` (2), `WindowFrameWriteTests` (1), più test `WindowInventoryTests`, `GeometryTests` e `ScreenRegionGeometryTests` (95 nel filtro combinato). Suite completa: 405 test superati, 0 falliti. Build strict concurrency pulita completata con 550 emissioni di warning; le maggiori concentrazioni sono `WindowIndex` e `WorkspaceStore`, con temi di callback, stato condiviso e trasferimenti worker/MainActor. Nessun benchmark o test manuale dell'app su desktop è stato eseguito.
