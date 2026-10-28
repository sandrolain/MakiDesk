# Analisi di performance, problemi e correzioni

Data: 28 ottobre 2026. Revisione analizzata: `1a55fa8` (`main`, working tree pulito). Segue [l'analisi del 26 ottobre](./analisi-ottimizzazioni-refactoring-bug-2026-10-26.md), di cui non ripete A01–A13.

## Perimetro e metodo

Analisi statica dei sorgenti Swift (82 file, circa 41.000 righe tra app e test), con attenzione alle parti introdotte o riscritte dopo il 26 ottobre: scorciatoie rimappabili, OCR, righello (Measure), color sampler, sorgenti screenshot, notifiche, posizionamento delle finestre utility, ordinamento della palette.

Ogni voce della sezione «Rilievi verificati» è stata letta nel codice corrente, con riferimento a file e simbolo. Le voci della sezione «Da confermare» derivano da una lettura parziale e vanno riprodotte prima di essere trattate come difetti. **Nessun benchmark, nessuna prova GUI e nessun test su desktop reale o più display**: i rilievi prestazionali descrivono lavoro eseguito sul main thread, non latenze misurate.

Priorità: **P1** perdita dati, consenso o processi attivi; **P2** comportamento errato o reattività; **P3** robustezza, privacy difensiva, manutenzione. Non sono stati individuati P1 in questa revisione.

## Stato di salute

| Controllo | Esito |
| --- | --- |
| `swift test` | 565 test eseguiti, 0 falliti (12,6 s) |
| Warning di concurrency nel build di default | 26 emissioni, 5 distinte: [WorkspaceStore.swift](../Sources/MakiDesk/WorkspaceStore.swift) (righe 3, 1421, 1592, 1630) e [TextRecognitionController.swift](../Sources/MakiDesk/TextRecognitionController.swift) (riga 88) |
| `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency` | **Non conclusivo.** Con scratch path separato il build ha tentato di riscaricare le dipendenze e fallito; sul build dir standard è terminato con codice 0 ma ha eseguito solo il link, quindi non si può affermare che il numero di warning del 26 ottobre (550) sia cambiato |
| Nuovo codice dopo il 26 ottobre | 22 commit, circa 7.700 righe aggiunte; i test coprono scorciatoie, OCR, Measure, color sampler e sorgenti screenshot |

## Riepilogo

| ID | Prio | Rilievo | Tipo |
| --- | --- | --- | --- |
| B01 | P2 | Lettura AX del focus sul main thread a ogni evento di focus | Reattività |
| B02 | P2 | Polling clipboard: `String.count` su testi illimitati sul main thread | Reattività |
| B03 | P2 | Watcher FSEvents inoltra solo i flag del primo evento del batch | Difetto |
| B04 | P3 | Letture AX sincrone per finestra nei comandi di layout | Reattività |
| B05 | P3 | Log stdout/stderr dei comandi senza limite di dimensione | Robustezza |
| B06 | P3 | Ambiente dell'app ereditato per intero dai comandi Dropzone | Privacy |
| B07 | P3 | Salvataggio di note esterne converte l'encoding senza avviso | Difetto |
| B08 | P3 | Contatori `registeredCount`/`failedCount` incoerenti dopo un reload | Difetto |
| B09 | P3 | Output OCR/colore/misura non marcato come transitorio sulla pasteboard | Privacy |
| B10 | P3 | Warning di concurrency residui e `assumeIsolated` non applicabile staticamente | Manutenzione |
| B11 | P3 | File molto grandi con responsabilità miste | Manutenzione |

## Rilievi verificati

### B01 — Lettura AX del focus sul main thread (P2)

**Evidenza.** [WorkspaceStore.swift](../Sources/MakiDesk/WorkspaceStore.swift) imposta `WindowIndex.shared.onFocusNow` (riga ~295) con un handler che chiama `WindowController.frontmost()` in modo sincrono; la stessa chiamata è nel completamento di `refreshRealWindows` (riga ~1759). `frontmost()` in [WindowController.swift](../Sources/MakiDesk/WindowController.swift) (riga ~455) esegue sul main actor: lettura della finestra a fuoco, posizione e dimensione, titolo, e in assenza della finestra nell'indice anche l'identificatore AX e `cgWindowNumbers()` (un `CGWindowListCopyWindowInfo` completo). [WindowOutlineController.swift](../Sources/MakiDesk/WindowOutlineController.swift) aggiunge `isFullScreen` e `isMinimized` per ogni refresh.

**Impatto.** Ogni cambio di focus esegue da 4 a 6 chiamate IPC verso l'app in primo piano, ciascuna con timeout di 0,1 s. Con un'app lenta il main thread può restare occupato per frazioni di secondo proprio mentre l'utente cambia finestra. Contraddice la regola «gli eventi di focus aggiornano il solo target» e quella sul lavoro AX fuori dal main thread.

**Intervento.** Leggere la finestra a fuoco sul worker AX e pubblicare sul main actor un valore, con controllo di generazione al momento della pubblicazione; preferire il dato dell'indice quando l'elemento è già noto. Evitare `cgWindowNumbers()` sul main thread. Misurare prima e dopo il tempo tra notifica e aggiornamento del bordo.

### B02 — Polling clipboard con costo proporzionale alla dimensione (P2)

**Evidenza.** [ClipboardHistory.swift](../Sources/MakiDesk/ClipboardHistory.swift), `poll()` (righe ~140–154): a ogni cambio della pasteboard (timer da 0,35 s sul main run loop) legge `pasteboard.string(forType: .string)` per intero e poi applica `text.count <= maximumLength` (1.000.000). `String.count` conta i grapheme cluster ed è lineare; lo stesso vale per `insert(_:)` (riga ~186).

**Impatto.** Copiare un testo molto grande, ad esempio un log o un file da decine di MB, materializza la stringa e la scorre per intero sul main thread prima di scartarla. La soglia protegge la memoria dello storico, non il costo della verifica.

**Intervento.** Escludere prima il caso grande con un controllo O(1) o limitato, ad esempio `text.utf8.count`, usando una soglia in byte coerente con il limite attuale; leggere la pasteboard solo se il tipo dichiarato non supera un limite. Aggiungere un test con testo oltre la soglia.

### B03 — Watcher FSEvents: flag del solo primo evento (P2)

**Evidenza.** [ScreenshotSources.swift](../Sources/MakiDesk/ScreenshotSources.swift), `ScreenshotFolderWatcher.start` (riga ~177): `let first = count > 0 ? flags[0] : 0` è l'unico valore inoltrato al gestore, mentre lo stream usa `kFSEventStreamCreateFlagWatchRoot` e il commento del tipo promette di segnalare la sostituzione della cartella.

**Impatto.** Se `RootChanged`, `MustScanSubDirs` o `UserDropped` compaiono in un evento successivo dello stesso batch, vengono persi e la libreria può restare su una cartella non più valida fino alla scansione successiva.

**Intervento.** Combinare con OR i flag di `flags[0..<count]` prima della chiamata. Il test può usare un gestore iniettato con flag sintetici.

### B04 — Letture AX sincrone per finestra nei comandi di layout (P3)

**Evidenza.** In [WorkspaceStore.swift](../Sources/MakiDesk/WorkspaceStore.swift) `arrangeableSet()` (riga ~1909) chiama `isFullScreen` per ogni finestra, e altri percorsi (righe ~2302, 2336, 2428, 2475, 2642) chiamano `isMinimized` per finestra. Gli elementi dell'indice hanno timeout di 0,05 s.

**Impatto.** Costo O(N) di round trip AX sul main thread a ogni comando di layout; con una sola app che non risponde il ritardo massimo è dell'ordine di N × 50 ms. Il caso normale è rapido, quindi è un limite di scala e non un blocco costante.

**Intervento.** Portare `fullScreen` e `minimized` nell'inventario asincrono già pubblicato dall'indice e leggere il valore dallo snapshot; ricorrere alla lettura diretta solo per il bersaglio di un singolo comando.

### B05 — Log dei comandi senza limite di dimensione (P3)

**Evidenza.** [CommandRunner.swift](../Sources/MakiDesk/CommandRunner.swift), `spawn` (righe ~190–193): stdout e stderr sono aperti con `O_WRONLY|O_CREAT|O_TRUNC`. Solo l'estratto letto è limitato (8 KiB e 64 KiB); il file no. Il timeout predefinito è 60 s, ma `0` lo disabilita e il massimo consentito è 3600 s (`CommandSpec.swift`, riga ~228).

**Impatto.** Un comando che produce output continuo può riempire il disco nella cache utente entro il timeout, o senza limite con timeout `0`.

**Intervento.** Applicare un limite di dimensione ai file di log (`RLIMIT_FSIZE` nel figlio o controllo periodico dal timer) e segnalarlo nel risultato; valutare un massimo di timeout anche quando `0` è accettato.

### B06 — Ambiente ereditato per intero dai comandi Dropzone (P3)

**Evidenza.** [CommandSpec.swift](../Sources/MakiDesk/CommandSpec.swift): `baseEnvironment` è `ProcessInfo.processInfo.environment` e `resolveEnvironment` parte da quella copia completa, sostituendo solo `PATH` e aggiungendo le variabili `MAKIDESK_*`.

**Impatto.** Variabili del contesto di avvio, comprese eventuali `DYLD_*` o credenziali, raggiungono ogni comando, anche importato. Il rischio è ridotto dalla conferma richiesta al primo avvio (A01), ma l'isolamento resta più ampio del necessario.

**Intervento.** Passare un elenco consentito (`HOME`, `USER`, `LANG`, `TMPDIR`, `PATH`, più quanto la zona dichiara) ed escludere `DYLD_*` salvo richiesta esplicita. Aggiungere un test con ambiente iniettato.

### B07 — Conversione silenziosa dell'encoding nel salvataggio esterno (P3)

**Evidenza.** [NotesStore.swift](../Sources/MakiDesk/NotesStore.swift), `write(text:to:encoding:)` (righe ~1186–1190): se la scrittura nell'encoding originale fallisce, ad esempio per un carattere non rappresentabile in Latin-1, ripete la scrittura in UTF-8 senza segnalarlo. `externalEncoding` della nota non viene aggiornato (righe ~600–611).

**Impatto.** Il testo non va perso, ma il file dell'utente cambia encoding senza avviso e lo stato della nota resta indicato con l'encoding precedente.

**Intervento.** Segnalare all'utente la conversione oppure restituire un errore; in ogni caso aggiornare `externalEncoding` dopo la scrittura riuscita.

### B08 — Contatori delle scorciatoie incoerenti (P3)

**Evidenza.** [ShortcutManager.swift](../Sources/MakiDesk/ShortcutManager.swift): `reload(_:)` azzera `registeredCount` e `failedCount` (righe ~71–72), ma i tasti dinamici di Peek ed Esc li incrementano e decrementano (righe ~170–187) e sopravvivono al reload.

**Impatto.** Dopo una rimappatura il conteggio registrato non include i tasti dinamici ancora attivi. L'effetto è limitato alla diagnostica nel log (`hotkeys registered=… blocked=…`), non al funzionamento delle scorciatoie.

**Intervento.** Calcolare i contatori da `hotKeys.count` e dai tasti dinamici correnti, o tenerli separati.

### B09 — Output delle utility senza marcatura transitoria (P3)

**Evidenza.** I marcatori `org.nspasteboard.ConcealedType` e `TransientType` compaiono solo in lettura, in [ClipboardHistory.swift](../Sources/MakiDesk/ClipboardHistory.swift) (righe ~101–102, 150). Le scritture di OCR, color sampler e Measure usano `clearContents()` e `setString` senza marcatura; con destinazione «clipboard e storico» il testo OCR entra anche nello storico interno.

**Impatto.** Un OCR eseguito su un campo sensibile può restare in gestori di appunti di terze parti e nello storico. Il comportamento è una scelta esplicita dell'utente, ma l'impostazione non lo rende evidente.

**Intervento.** Offrire la marcatura transitoria per le destinazioni «solo storico» e valutare di non registrare nello storico quando è attivo l'input sicuro.

### B10 — Concurrency: warning residui e `assumeIsolated` (P3)

**Evidenza.** Il build di default emette ancora 5 warning distinti (tabella «Stato di salute»). Il codice contiene circa 36 usi di `MainActor.assumeIsolated` nei callback di timer e notifiche, e una ventina di tipi `@unchecked Sendable` (ad esempio in [WindowIndex.swift](../Sources/MakiDesk/WindowIndex.swift), [ShelfController.swift](../Sources/MakiDesk/ShelfController.swift), [AXFrameWriteCoordinator.swift](../Sources/MakiDesk/AXFrameWriteCoordinator.swift)). I commenti dichiarano l'invariante di proprietà.

**Impatto.** `assumeIsolated` termina l'app a runtime se il callback viene un giorno consegnato su un altro thread; l'invariante è documentata ma non verificata dal compilatore. I tre warning di `WorkspaceStore` riguardano la cattura di `AXUIElement` in closure `@Sendable`.

**Intervento.** Incapsulare `AXUIElement` in un wrapper `Sendable` unico (oggi ne esistono più copie locali in `WindowIndex`), correggere il default argument di `TextRecognitionController`, e ripetere il build strict su una cache pulita per ottenere un numero confrontabile.

### B11 — File molto grandi (P3)

[WorkspaceStore.swift](../Sources/MakiDesk/WorkspaceStore.swift) (3.470 righe), [ShelfController.swift](../Sources/MakiDesk/ShelfController.swift) (2.461), [WindowPalette.swift](../Sources/MakiDesk/WindowPalette.swift) (2.365), [NotesPanel.swift](../Sources/MakiDesk/NotesPanel.swift) (1.488) e [NotesStore.swift](../Sources/MakiDesk/NotesStore.swift) (1.192) concentrano più responsabilità. `WorkspaceStore` è cresciuto di circa 650 righe dopo il 26 ottobre. Proseguire l'estrazione iniziata con `AXFrameWriteCoordinator` (R01), partendo dai blocchi che B01 e B04 toccano comunque: lettura del focus e disposizione delle finestre.

## Da confermare

Segnalazioni emerse da una lettura parziale, non riprodotte né verificate riga per riga.

| Tema | File | Sospetto | Verifica proposta |
| --- | --- | --- | --- |
| Display delle finestre utility | [UtilityWindowPlacement.swift](../Sources/MakiDesk/UtilityWindowPlacement.swift) | `focusedScreen()` si basa su `NSScreen.main`; con un'app accessory non attiva potrebbe indicare il display sbagliato | Prova manuale con due display e un'altra app in primo piano; in caso di errore usare il frame della finestra a fuoco dallo snapshot dell'indice |
| Confronto display | stesso file, `sameDisplay` | Confronta `NSScreen.frame`: display in mirroring o spostati possono risultare uguali o diversi | Confrontare `NSScreenNumber` |
| Pin del righello dopo cambio display | [MeasureController.swift](../Sources/MakiDesk/MeasureController.swift) | Nessun osservatore di `didChangeScreenParametersNotification` (assente nel file); `visibleFrame` è memorizzato al momento del pin | Scollegare un display con pin attivi |
| OCR non annullabile durante Vision | [TextRecognizer.swift](../Sources/MakiDesk/TextRecognizer.swift) (`handler.perform`, riga ~175) | `perform` è sincrono; l'annullamento è controllato solo prima e dopo. Il risultato obsoleto viene scartato dalla generazione, ma il lavoro continua | Ripetere la scorciatoia OCR e osservare la CPU; valutare di ignorare le richieste mentre una è in corso |
| `canRegister` con scorciatoia già nostra | [ShortcutManager.swift](../Sources/MakiDesk/ShortcutManager.swift) | Registrare di prova la combinazione già assegnata a un'altra riga può dare «occupata» | Registrare nel recorder una combinazione già in uso da MakiDesk |
| Cattura con overlay | [ScreenRegionSelector.swift](../Sources/MakiDesk/ScreenRegionSelector.swift) (`finish`) | Se manca lo snapshot, la cattura parte subito dopo la chiusura dell'overlay | Selezione immediata su un display appena visitato |
| Output Dropzone troncato | [CommandRunner.swift](../Sources/MakiDesk/CommandRunner.swift) (`excerpt`) | Oltre 64 KiB il payload testuale è troncato senza indicazione e un carattere multibyte tagliato diventa U+FFFD | Comando con output lungo e destinazione clipboard |
| `SCShareableContent` a ogni cattura | [ScreenRegionCapture.swift](../Sources/MakiDesk/ScreenRegionCapture.swift) | Enumerazione completa delle finestre anche quando basta il display | Profilare il tempo di cattura con molte finestre |

## Parti già solide

- Le scritture di bozze, sessione e gruppi sono atomiche e serializzate; il salvataggio asincrono confronta la revisione prima di azzerare lo stato dirty.
- Lo storico clipboard ha un limite di voci, rispetta i tipi concealed/transient e registra solo metriche aggregate, senza contenuto.
- `shellQuote`, il tokenizer degli argomenti, il lock di `ProcessRun` e l'escalation SIGTERM→SIGKILL risultano coerenti; l'ambiente del processo figlio ha segnali ripristinati.
- Gli overlay di selezione e l'osservatore di resign sono smontati in `tearDown`; i controller OCR e color sampler usano una generazione per scartare i risultati obsoleti.
- Monitor degli eventi e osservatori hanno rimozione corrispondente nei file controllati; i timer di polling usano `.common` e hanno `invalidate` esplicito.
- `PanelFocusReturn` limita la lettura AX a una sola finestra con timeout locale di 0,1 s, come dichiarato.

## Ordine di lavoro proposto

1. B03 e B02: correzioni piccole, con test deterministici e senza GUI.
2. B01 e B04: stesso confine (inventario asincrono e snapshot); misurare con build release prima e dopo, riportando ambiente, campioni e mediana/p95/massimo, separando evento→handler, letture AX e prima risposta visibile.
3. B05–B09: correzioni circoscritte; B06 e B09 richiedono una decisione sul comportamento atteso.
4. B10–B11 in modo incrementale, ripetendo il build strict su cache pulita come baseline.
5. Verificare manualmente la sezione «Da confermare» con una sola istanza dell'app e almeno due display.

## Verifiche di questa consegna

Eseguiti: lettura del codice citato, `swift test` (565 superati) e `swift build` di default con osservazione dei warning. Non eseguiti: benchmark, build release, prove manuali, test su più display, modifica di dati utente o permessi. Nessun file applicativo era stato modificato in quella fase; lo stato dopo le correzioni è nel ledger.

## Ledger implementazione — 2026-10-28

Correzioni applicate dopo l'analisi. Test: suite completa 581 superati, 0 falliti (16 nuovi). Nessuna prova GUI, nessun benchmark.

| Rilievo | Stato | Modifica e verifica |
| --- | --- | --- |
| B01 | Corretto in codice, **da provare su desktop** | La lettura della finestra a fuoco passa da `WindowController.readFocusedWindow` (`nonisolated`, snapshot dell'indice passato per valore) su una coda dedicata, governata da [FocusReadCoordinator.swift](../Sources/MakiDesk/FocusReadCoordinator.swift): una lettura alla volta, una richiesta durante la lettura la rende obsoleta e ne segue un'altra, idem se cambia l'app frontale (massimo 2 ripetizioni, poi consegna `.none`). `WorkspaceStore.applyFocusRead` pubblica sul main actor. `onFocusChange` non ricade più sulla lettura sincrona. Test deterministici della politica con lettore iniettato (4: lettura singola, nessuna app frontale, richiesta durante la lettura, app che cambia). Restano sincroni `isFullScreen`/`isMinimized` del bordo di focus e il fallback di `refresh()` senza snapshot. La lettura AX reale non è coperta: verificare bordo, MRU e mini-mappa con app lente e cambi rapidi di focus |
| B02 | Corretto | Limite verificato in unità UTF-16 invece di `String.count`. Test su testo oltre soglia (ASCII ed emoji) |
| B03 | Corretto | `ScreenshotFolderWatcher.combine` unisce i flag di tutti gli eventi del batch. Test dedicato |
| B04 | Corretto per i comandi di layout | `WindowInfo.fullScreen` letto durante la discovery sul worker; `arrangeableSet` non fa più letture AX per finestra sul main thread (logica estratta in `arrangeableSet(from:appHidden:)`, pura). I comandi di layout attendono già un inventario fresco (`deferUntilFreshInventory`). Test sull'ordinamento per flag. Restano letture live, volute ("realtà, non cache"), nei percorsi di scena/gruppo (`putAwayNonMembers`, reveal, step-back) e per il singolo bersaglio dei comandi di tiling. La discovery aggiunge una lettura `AXFullScreen` per finestra non minimizzata: costo non misurato |
| B05 | Corretto | Timer a 0,5 s controlla stdout/stderr; oltre 256 MiB per file il gruppo di processi è terminato, `CommandResult.outputLimitExceeded` è vero e `succeeded` falso. Limite iniettabile; test con `yes` e con output piccolo |
| B06 | Parziale | Rimosse le variabili `DYLD_*` ereditate (restano quelle dichiarate dalla zona). Non è stato introdotto un elenco consentito: romperebbe comandi che usano `SSH_AUTH_SOCK`, proxy o `LANG`. Test dedicato |
| B07 | Corretto | `NotesStore.effectiveEncoding` sceglie UTF-8 prima della scrittura quando il testo non è rappresentabile; l'encoding effettivo viene salvato nella nota, nel percorso sincrono e asincrono. Nessun avviso all'utente. Test |
| B08 | Corretto | `registeredCount` e `failedCount` sono calcolati dallo stato corrente. Nessun test: richiede registrazione Carbon reale |
| B09 | Corretto in forma mirata | Decisione presa senza input dell'utente, da confermare: marcare sempre la pasteboard come concealed avrebbe tolto l'OCR ai gestori di appunti di terze parti, quindi l'OCR marca `org.nspasteboard.ConcealedType` **solo quando l'input sicuro è attivo** (probabile campo password). Lo storico interno non cambia (l'OCR resta una richiesta esplicita). Test per i due casi; `docs/PRIVACY.md` aggiornato. Color sampler e righello non sono marcati: producono colori e misure, non testo letto dallo schermo |
| B10 | Corretto per i warning | Un build strict (`-strict-concurrency=complete -warn-concurrency`) mostrava 23 warning distinti nei sorgenti, ora tutti corretti: `ApplicationCatalog` isolato a `@MainActor` con `scan` e callback `@Sendable`; `SendableAXElement` condiviso e `completion`/`finish` `@MainActor @Sendable` nelle animazioni di `WorkspaceStore`; timer di `MiniMapController` e animazioni senza catturare `Timer` nelle closure concorrenti; `NotificationToken` al posto del `deinit` di `LineNumberRulerView`; `PaletteTheme.isDark` `@MainActor` (test class `@MainActor`); `CaptureBatch` `Sendable`; `kAXTrustedCheckOptionPrompt` sostituito dalla chiave letterale `AXTrustedCheckOptionPrompt`; default `history` di `TextRecognitionController` risolto nel corpo dell'init. Verifica: build strict con scratch path pulito, 0 warning di concorrenza nei sorgenti; restano 2 warning preesistenti di cattura weak (`WorkspaceStore` 1549, `NotesStore` 1085). Attenzione: i build strict incrementali nella cartella `.build` di questa sessione hanno dato conteggi incoerenti (0, 23, 0); fa fede solo il build pulito. Restano circa 36 `MainActor.assumeIsolated` nei callback di timer/notifica: invariante documentata, non imposta dal compilatore |
| B11 | Parziale | Estratto da `WorkspaceStore.swift` il blocco puro del layout (`LayoutDisposition`, `ArrangeableSet`, `arrangeableSet(from:)`, `layoutSummary`) in [WorkspaceStore+LayoutSet.swift](../Sources/MakiDesk/WorkspaceStore+LayoutSet.swift), come estensione: API e test invariati. Restano i blocchi grandi (lettura del focus, animazioni, scene/gruppi, Dropzone di `ShelfController`, palette) |

### Sospetti «Da confermare»: esito

| Tema | Esito |
| --- | --- |
| Pin del righello dopo cambio display | Confermato e corretto: `MeasureController` osserva `didChangeScreenParametersNotification` e rimuove i pin il cui display non esiste più con lo stesso frame (`isAnchored`, testato) |
| Output Dropzone troncato | Confermato e corretto: se stdout supera l'estratto (64 KiB) `DropzoneOutput.payload` consegna il file di log completo invece di testo tagliato. Test dedicato |
| Cattura con overlay | Mitigato: la cattura finale senza snapshot esclude le finestre overlay, come già faceva lo snapshot. Non riproducibile senza GUI |
| OCR non annullabile durante Vision | Corretto: `withTaskCancellationHandler` chiama `VNRequest.cancel()`; un'annullata non è più riportata come errore Vision. Nessun test deterministico |
| `canRegister` con scorciatoia già nostra | Non è un difetto: `setShortcut` salta la sonda per la combinazione già assegnata alla riga e `validationError` rifiuta i duplicati della tabella |
| `NSScreen.main` e confronto display in `UtilityWindowPlacement` | Non modificato: serve prova manuale con due display |
| `SCShareableContent` a ogni cattura | Non modificato: serve profilazione |
