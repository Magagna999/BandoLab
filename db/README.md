# BandoLab — Database e API

Schema per PostgreSQL / Supabase in `schema.sql`, più le patch numerate. Corrisponde ai modelli di `bandolab-core.js`.
Il contratto delle funzioni RPC è in [`API.md`](API.md).

## Principi
- **Ambienti separati**: ogni tabella di contenuto ha la colonna `env` (`demo` | `real`) nella chiave primaria. I dati demo non possono finire nel reale.
- **ID stabili**: le associazioni usano ID (`s-amm`, `q01`…), mai i nomi visualizzati.
- **Autore ≠ revisore**: vale per editor e revisori; un amministratore può approvare e pubblicare i propri contenuti (patch 09). Per le domande la regola è nel trigger `question_versions_self_review`.
- **Versioni**: `questions` punta a `current_version`; le modifiche creano righe nuove in `question_versions`. `attempt_items` conserva la versione usata.
- **Nessuna eliminazione automatica**: sospensione (`suspended`) e consolidamento (`merged_into`) invece di `DELETE`.
- **Permessi lato server**: RLS sulle letture, funzioni RPC `security definer` (con `search_path` fisso) per le transizioni.
- **Soluzioni protette**: `correct` ed `explanation` non sono leggibili dal client; si ottengono solo dalle RPC.
- **Punteggio**: `compute_score()` replica `BL.computeScore` (stessa formula, soglia 21 sul valore non arrotondato).

## Patch
| File | Contenuto | Stato nel database |
|---|---|---|
| `schema.sql` | tabelle, RLS, `compute_score` | applicato |
| `patch-01` … `patch-05` | regole RLS, sicurezza, prestazioni, indici | applicate |
| `patch-06-hardening.sql` | segnalazioni, notifiche e note di sospensione più restrittive | applicata |
| `patch-07-rpc-sessions.sql` | RPC per sessioni, punteggio, XP, percorsi | applicata |
| `patch-08-hide-answers.sql` | viste senza soluzioni, permessi per colonna, RPC per soluzioni | applicata |
| `patch-09-admin-self-review.sql` | un amministratore può essere autore e revisore dello stesso contenuto (trigger al posto del vincolo) | applicata |
| `patch-10-rpc-user.sql` | RPC area utente: materiali, revisione errori, segnalazioni, esportazione e cancellazione dati; notifiche aggiornabili solo in `read_at` | applicata |
| `patch-11-rpc-questions.sql` | RPC redazione delle domande: creazione, bozze, transizioni, segnalazioni, duplicati, import | applicata |
| `patch-12-rpc-content.sql` | RPC materiali, quiz, catalogo e ruoli | applicata |

Ordine di esecuzione su un progetto nuovo: schema, poi le patch in ordine numerico.

## Funzioni RPC
Tutte **implementate e testate** (dettaglio in [`API.md`](API.md)).

| Gruppo | Funzioni |
|---|---|
| Sessioni (07) | `start_session`, `save_session`, `finish_session`, `log_interruption`, `abandon_session` |
| Soluzioni (08) | `get_question_feedback`, `get_attempt_review`, `get_question_version_staff` |
| Area utente (10) | `complete_material`, `mark_reviewed`, `create_report`, `export_my_data`, `delete_my_account` |
| Domande (11) | `create_question`, `update_draft`, `transition`, `update_report`, `decide_duplicate`, `import_questions` |
| Materiali e quiz (12) | `create_material`, `update_material`, `set_material_file`, `material_transition`, `save_quiz`, `set_quiz_status` |
| Catalogo e ruoli (12) | `tax_edit`, `set_role` |

Ogni RPC che modifica contenuti scrive una riga in `audit_log`. Differenza voluta rispetto al prototipo: lato server un editor modifica solo le proprie bozze.

## Dati demo
`seed-demo.sql` carica l'ambiente `demo` con i dati del prototipo: tassonomia, 53 domande (54 versioni: 50 pubblicate, 1 in revisione, 1 bozza, 1 con modifiche richieste, più una seconda versione in revisione), 8 materiali, 5 quiz, 2 percorsi e 3 utenti di redazione fittizi (2 editor e 1 revisore, email `@example.com`, senza possibilità di accesso).
Il file è generato da `bandolab-core.js` con `node db/tools/generate-demo-seed.js` ed è idempotente (`on conflict do nothing`). **Stato: caricato nel database il 27/10/2026.** L'ambiente `real` è ancora vuoto.
I materiali in PDF restano in bozza finché non c'è un file nello storage (vincolo `file_path` del database).
Nota: il database ha fatto emergere due difetti dei dati demo che il prototipo non controllava (testo di `q41` troppo corto, date vuote nelle bozze): il primo è corretto nel core.

## Caricamento delle domande reali (da Excel)
1. Compilare `import/modello-domande.xlsx` (fogli «Domande» e «Tassonomia»; le celle gialle sono obbligatorie, la riga «ESEMPIO» viene ignorata).
2. Controllare e generare l'SQL:
   `python3 db/tools/excel-to-sql.py FILE.xlsx --author UUID [--env real] [--status draft|review|published] [--reviewer UUID]`
   Lo script applica le regole del database (testo ≥ 10 caratteri, 4 opzioni, risposta A–D, spiegazione e fonte obbligatorie, difficoltà 1–3, argomento coerente con la materia, date, duplicati) e, se c'è anche un solo errore, elenca le righe da correggere senza scrivere nulla.
3. Eseguire l'SQL ottenuto nel database (editor SQL di Supabase o `execute_sql`). È ripetibile: gli ID già presenti non vengono duplicati.
Con `--status published` serve `--reviewer` diverso da `--author` (vincolo del database). Senza ID in colonna A le domande ricevono ID `r0001…` (`--start` per proseguire una numerazione).
`import/modello-domande.xlsx` si rigenera con `python3 db/tools/make-excel-template.py`.
Prerequisito: l'autore deve essere un utente esistente (`profiles_user`). Finché non c'è il login Google si può usare uno degli utenti di redazione del seed demo.
Verifica: un file di prova importato come pubblicato nell'ambiente `real` risulta visibile agli utenti anonimi tramite `live_questions` (prova annullata, nessun dato lasciato).
Dall'interfaccia si può caricare con `import_questions` (solo amministratori).

## Test
`tests/rpc-sessions.test.sql` è un blocco `DO` che crea utenti e domande fittizi, simula i ruoli con `set local role` e `request.jwt.claims`, verifica 39 casi (T01–T33) e termina sempre con un errore `RISULTATI: ...` che annulla ogni modifica.
Si esegue nell'editor SQL di Supabase (o con `execute_sql`) e non lascia dati. Esito del 27/10/2026: tutti i controlli ok.
Altri tre blocchi con lo stesso schema, tutti passati il 27/10/2026: `tests/rpc-user.test.sql` (U01–U21: materiali, revisione, segnalazioni, esportazione, cancellazione), `tests/rpc-editorial.test.sql` (E01–E41: permessi per ruolo, autore/revisore, transizioni, segnalazioni, duplicati, import) e `tests/rpc-content.test.sql` (44 controlli: materiali, quiz, catalogo, ruoli).
Copre: avvio e bilanciamento, sessione già aperta, dati non validi, salvataggio, feedback, punteggio e XP, idempotenza, revisione, scadenza e tolleranza, bonus miglioramento, interruzioni, abbandono, percorso, preferenze notifiche, accesso anonimo, funzione staff, soglia di superamento, precedenza agli errori passati.

## Livello API del sito (`bandolab-api.js`)
Modulo senza dipendenze (oltre a supabase-js) che chiama il database al posto di `localStorage`. Tutte le funzioni sono asincrone e non sollevano eccezioni: ritornano `{ ok:true, ... }` oppure `{ ok:false, error, why }` con messaggio in italiano.
- **Accesso**: `signInWithGoogle`, `signOut`, `getUser`, `onAuthChange`, `getProfile`.
- **Sessioni**: `startSession`, `saveSession`, `finishSession`, `logInterruption`, `abandonSession`, `getActiveSession` (riprende dopo la chiusura del browser).
- **Soluzioni**: `getQuestionFeedback`, `getAttemptReview`, `getQuestionVersionStaff`.
- **Lettura**: `listAttempts`, `listXp`, `listNotifications`, `getPathProgress`, `getTaxonomy`, `listQuizzes`, `listMaterials`, `listPaths`. I dati tornano già nel formato usato dal core (camelCase, date in millisecondi, punteggio con `display`).
- **Timer**: la sessione include `clockSkew` (scarto tra orologio del server e del dispositivo) per mostrare la scadenza corretta; la scadenza vera la decide il server.
Nel browser: caricare supabase-js, poi `const api = BandoLabAPI.connect();`. URL del progetto e chiave pubblica (publishable) sono nel file; la sicurezza dei dati è nelle regole RLS.
Materie, argomenti, sezioni dei materiali e percorsi sono leggibili solo dopo l'accesso; quiz e materiali pubblicati anche da anonimi.
- **Area utente**: `completeMaterial`, `markReviewed`, `createReport`, `exportMyData`, `deleteMyAccount`.
- **Redazione**: `createQuestion`, `updateDraft`, `transition`, `updateReport`, `decideDuplicate`, `importQuestions`, `createMaterial`, `updateMaterial`, `setMaterialFile`, `materialTransition`, `saveQuiz`, `setQuizStatus`, `taxEdit`, `setRole`. Il server ricontrolla ruoli e regole.
Resta da fare solo la scrittura delle preferenze (letta e scritta oggi dalla tabella `user_prefs`).
**Collegamento alle pagine**: scelta di sicurezza, nessuna copia locale dei dati del server: le pagine chiamano direttamente questo modulo (il server decide punteggi, scadenze e soluzioni; il core resta solo per il demo anonimo). Fatto: Landing (accesso con Google, flusso PKCE, utente connesso e uscita). Da fare: App utente, poi Admin.
Test: `test/api.test.js` (17 test; la Landing è provata in browser con la libreria vera e le chiamate al database intercettate, client Supabase finto in `test/helpers/fake-supabase.js`). Verificato sul database reale che tutte le tabelle e colonne lette esistono.

## Passi per il collegamento
1. Progetto Supabase creato, schema e patch 01–12 applicati (fatto).
2. Attivare il provider Google in Authentication e impostare Site URL e redirect (vedi `GUIDA-SUPABASE.md`).
3. Popolare la tassonomia dell'ambiente `real` solo con contenuti revisionati.
4. In `bandolab-core.js` sostituire `BL.commit` e le funzioni elencate con chiamate a `supabase.rpc(...)` (livello `bandolab-api.js`, prossimo passo).
5. Aggiungere test end-to-end sui flussi elencati in `BandoLab Test.dc.html`.

## Limiti noti e punti aperti
- `anon` e `authenticated` hanno i privilegi di tabella completi: protegge solo la RLS. Da restringere con una patch dedicata (compreso `TRUNCATE`).
- `review_note`, `change_note`, `author_id` e `reviewer_id` delle domande pubblicate sono leggibili dagli utenti.
- In allenamento il server si fida del flag "rivelata" inviato dal client.
- Non vengono ancora create notifiche per i badge.
- Il Security Advisor segnala 27 avvisi attesi (funzioni `security definer` eseguibili da `authenticated`: sono le RPC pubbliche) e uno sull'impostazione di Auth «leaked password protection», da attivare in Supabase (non riguarda l'accesso con Google).
