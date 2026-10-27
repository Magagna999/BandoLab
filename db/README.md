# BandoLab — Database e API

Schema per PostgreSQL / Supabase in `schema.sql`, più le patch numerate. Corrisponde ai modelli di `bandolab-core.js`.
Il contratto delle funzioni RPC è in [`API.md`](API.md).

## Principi
- **Ambienti separati**: ogni tabella di contenuto ha la colonna `env` (`demo` | `real`) nella chiave primaria. I dati demo non possono finire nel reale.
- **ID stabili**: le associazioni usano ID (`s-amm`, `q01`…), mai i nomi visualizzati.
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

Ordine di esecuzione su un progetto nuovo: schema, poi le patch in ordine numerico.

## Funzioni RPC
| Funzione | Stato |
|---|---|
| `start_session`, `save_session`, `finish_session`, `log_interruption`, `abandon_session` | **implementate e testate** |
| `get_question_feedback`, `get_attempt_review`, `get_question_version_staff` | **implementate e testate** |
| `complete_material(mid)` | da implementare |
| `create_report(qid, v, reason, text)` | da implementare (la policy di inserimento esiste) |
| `create_question()`, `update_draft(qid, fields)` | da implementare |
| `transition(qid, action, note)` | da implementare — submit, approve, changes, reject, publish, newVersion, suspend, unsuspend, verify, reopen |
| `material_transition(mid, action)` | da implementare |
| `set_quiz_status(zid, status)` | da implementare — controlli di `BL.quizChecks` |
| `decide_duplicate(a, b, decision, note)` | da implementare |
| `tax_edit(kind, id, patch)` | da implementare |
| `set_role(uid, role)` | da implementare |
| `export_my_data()`, `request_account_deletion()` | da implementare (GDPR) |

Ogni RPC che modifica contenuti dovrà scrivere una riga in `audit_log`.

## Dati demo
`seed-demo.sql` carica l'ambiente `demo` con i dati del prototipo: tassonomia, 53 domande (54 versioni: 50 pubblicate, 1 in revisione, 1 bozza, 1 con modifiche richieste, più una seconda versione in revisione), 8 materiali, 5 quiz, 2 percorsi e 3 utenti di redazione fittizi (2 editor e 1 revisore, email `@example.com`, senza possibilità di accesso).
Il file è generato da `bandolab-core.js` con `node db/tools/generate-demo-seed.js` ed è idempotente (`on conflict do nothing`). **Stato: caricato nel database il 27/10/2026.** L'ambiente `real` è ancora vuoto.
I materiali in PDF restano in bozza finché non c'è un file nello storage (vincolo `file_path` del database).
Nota: il database ha fatto emergere due difetti dei dati demo che il prototipo non controllava (testo di `q41` troppo corto, date vuote nelle bozze): il primo è corretto nel core.

## Caricamento delle domande reali
Per ora non esiste un import da interfaccia. Il canale è SQL, con lo stesso schema del seed: una riga in `questions`, una o più in `question_versions` (4 opzioni, risposta 0–3, spiegazione, materia, argomento, difficoltà 1–3, fonte, `last_verified`, `next_review`), poi `current_version`.
Prerequisiti: materie e argomenti dell'ambiente `real` già presenti; un autore (utente esistente in `profiles_user`) e, per pubblicare, un revisore diverso dall'autore. Altrimenti le domande restano in bozza.
Prossimo passo previsto: funzione `import_questions(jsonb)` riservata agli admin (tutto o niente), con un modello CSV/Excel da compilare.

## Test
`tests/rpc-sessions.test.sql` è un blocco `DO` che crea utenti e domande fittizi, simula i ruoli con `set local role` e `request.jwt.claims`, verifica 39 casi (T01–T33) e termina sempre con un errore `RISULTATI: ...` che annulla ogni modifica.
Si esegue nell'editor SQL di Supabase (o con `execute_sql`) e non lascia dati. Esito del 27/10/2026: tutti i controlli ok.
Copre: avvio e bilanciamento, sessione già aperta, dati non validi, salvataggio, feedback, punteggio e XP, idempotenza, revisione, scadenza e tolleranza, bonus miglioramento, interruzioni, abbandono, percorso, preferenze notifiche, accesso anonimo, funzione staff, soglia di superamento, precedenza agli errori passati.

## Passi per il collegamento
1. Progetto Supabase creato, schema e patch 01–08 applicati (fatto).
2. Attivare il provider Google in Authentication e impostare Site URL e redirect (vedi `GUIDA-SUPABASE.md`).
3. Popolare la tassonomia dell'ambiente `real` solo con contenuti revisionati.
4. In `bandolab-core.js` sostituire `BL.commit` e le funzioni elencate con chiamate a `supabase.rpc(...)` (livello `bandolab-api.js`, prossimo passo).
5. Aggiungere test end-to-end sui flussi elencati in `BandoLab Test.dc.html`.

## Limiti noti e punti aperti
- `anon` e `authenticated` hanno i privilegi di tabella completi: protegge solo la RLS. Da restringere con una patch dedicata (compreso `TRUNCATE`).
- `review_note`, `change_note`, `author_id` e `reviewer_id` delle domande pubblicate sono leggibili dagli utenti.
- In allenamento il server si fida del flag "rivelata" inviato dal client.
- Non vengono ancora create notifiche per i badge.
- Il Security Advisor segnala 8 avvisi attesi (funzioni `security definer` eseguibili da `authenticated`).
