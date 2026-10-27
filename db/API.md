# BandoLab — Contratto delle funzioni RPC

Funzioni disponibili dopo le patch 07, 08, 10, 11 e 12. Tutte richiedono un utente autenticato (`authenticated`);
gli anonimi ricevono `permission denied`. Si chiamano con `supabase.rpc(nome, parametri)`.

Convenzioni:
- Gli esiti "normali" tornano come `{ ok: false, error: '<codice>' }` (nessuna eccezione).
- Dati non validi o accesso negato sollevano eccezioni Postgres: `22023` (dati non validi), `28000` (non autenticato), `42501` (non autorizzato).
- Le funzioni nello schema `private` non sono chiamabili dall'API.
- Il server decide le scadenze: il client mostra il timer ma non lo controlla (`server_now` serve a calcolare lo scarto).

## Sessioni di quiz

### `start_session(cfg jsonb)`
| Campo di `cfg` | Note |
|---|---|
| `env` | `demo` \| `real` |
| `mode` | `training` \| `exam` |
| `title`, `key` | titolo visibile e chiave di ripetizione (usata per il limite XP) |
| `count` | 1–200 |
| `duration_min` | 1–360, solo per `exam` |
| `filter` | `{subjects, topics, difficulty, profile}` (opzionale) |
| `path_ref` | `{pid, sid}` per collegare la sessione a un passo di percorso (opzionale) |

Ritorna `{ok:true, prioritized, session:{id, items, deadline, server_now, ...}}`. Le soluzioni non sono mai incluse.
Errori: `session_exists` (c'è già una sessione aperta), `insufficient` (con `available`).
Le simulazioni scadute dell'utente vengono consegnate automaticamente all'avvio di una nuova sessione.
Le domande sono bilanciate tra le materie; dopo almeno 30 risposte storiche vengono scelte prima quelle sbagliate in passato (`prioritized: true`).

### `save_session(p_id uuid, p_answers jsonb, p_revealed jsonb = null, p_current int = null)`
Salva risposte (`{qid: indice 0–3}`), domande rivelate (solo allenamento) e posizione corrente (se omessa non viene modificata).
Errori: `session_not_found`, `expired` (simulazione oltre la scadenza). Eccezione `22023` per risposte fuori scala o domande estranee.

### `finish_session(p_id uuid, p_reason text = 'submitted')`
`p_reason`: `submitted` | `timeout`. Calcola punteggio (C − 0.5·E − 0.25·O, scala 30, superato da 21 sul valore non arrotondato), assegna XP, aggiorna il percorso, crea la notifica (se le preferenze lo consentono).
Una consegna dopo la scadenza viene registrata come `timeout` con durata pari alla durata prevista. Tolleranza di 5 s sul `timeout` anticipato.
Idempotente: una seconda chiamata ritorna `already: true`.
Ritorna `{ok, attempt:{id, mode, title, status, reason, started_at, finished_at, duration_sec, c, e, o, n, raw, score, display, passed}, xp:[{amount, reason}]}`.
Errori: `session_not_found`, `not_expired` (timeout richiesto prima della scadenza).

XP: 10 + risposte corrette; 0 dopo 2 ripetizioni della stessa chiave in 24 h; +15 per miglioramento in una simulazione confrontabile.

### `log_interruption(p_id uuid, p_type text)`
Registra un'interruzione (massimo 200, tipo di 1–40 caratteri). Errore: `session_not_found`.

### `abandon_session(p_id uuid)`
Chiude la sessione come abbandonata (durata = tempo effettivo). Idempotente (`already: true`).

## Soluzioni

Le colonne `correct` ed `explanation` non sono leggibili dalle tabelle e dalle viste. Si ottengono solo da queste funzioni.

### `get_question_feedback(p_session_id uuid, p_qid text)`
Solo allenamento e solo per domande segnate come rivelate. Ritorna `{ok, qid, v, correct, explanation}`.
Errori: `session_not_found`, `not_available` (simulazione), `question_not_in_session`, `not_revealed`.

### `get_attempt_review(p_attempt_id uuid)`
Revisione di un proprio tentativo consegnato, con testo, opzioni, risposta data, soluzione, spiegazione e fonte nella versione usata.
Errore: `attempt_not_found` (anche per tentativi di altri utenti).

### `get_question_version_staff(p_env env_t, p_qid text, p_v int)`
Versione completa di una domanda per editor, revisori e amministratori; gli altri ricevono `42501`. Errore: `not_found`.

## Area utente (patch 10)

### `complete_material(p_env, p_mid)`
Segna un materiale pubblicato come completato: +8 XP una sola volta e avanzamento dei percorsi che lo contengono. Esiti: `{ok:true, already:false, xp:8}`, `{ok:true, already:true}`, errore `not_found`.

### `mark_reviewed(p_attempt_id)`
Revisione degli errori di un proprio tentativo concluso: +5 XP una sola volta. Errore `attempt_not_found`.

### `create_report(p_env, p_qid, p_v, p_reason, p_text)`
Segnalazione di una versione pubblicata. Motivo 2–60 caratteri, descrizione 10–2000 (altrimenti `22023`). Massimo 5 al giorno (`too_many`). Crea una notifica se le preferenze lo consentono. Ritorna `{ok:true, id}`.

### `export_my_data()`
Tutti i dati personali dell'utente in un unico JSON (profilo, preferenze, tentativi con risposte, XP, letture, percorsi, notifiche, segnalazioni).

### `delete_my_account(p_confirm)`
Cancella l'account e i dati personali; `p_confirm` deve essere `'ELIMINA'` (altrimenti `22023`). Gli account di redazione, o con contenuti o decisioni a proprio nome, ricevono `staff_account`: l'amministratore deve prima riassegnarli. Le segnalazioni restano anonime.

Le notifiche sono aggiornabili dal client solo nella colonna `read_at`.

## Redazione: domande (patch 11)
Ruoli: editor, revisori e amministratori; chi non ha il ruolo riceve `42501`. Ogni modifica scrive una riga in `audit_log`.
Regola di autore/revisore: editor e revisori non possono approvare un proprio contenuto (`self_review`); l'amministratore sì. Un editor modifica solo le proprie bozze (`not_author`).

- `create_question(p_env)` → `{ok, id, v}` nuova bozza.
- `update_draft(p_env, p_qid, p_fields)` — campi ammessi: `text, options[4], correct, explanation, subject_id, topic_id, difficulty, source, source_url, last_verified, next_review`. Dati non validi: `22023`.
- `transition(p_env, p_qid, p_action, p_note = null)` — azioni: `submit, approve, changes, reject, publish, newVersion, suspend, unsuspend, verify, reopen`. `changes`, `reject` e `suspend` richiedono una nota (`note_required`). Errori: `not_found`, `invalid_state`, `validation`, `self_review`.
- `update_report(p_id, p_patch)` — `status`, `priority`, `assignee_id`.
- `decide_duplicate(p_env, p_a, p_b, p_decision, p_note = null)` — registra la decisione sulla coppia.
- `import_questions(p_env, p_rows, p_status = 'draft')` — solo amministratori; `p_status` è `draft`, `review` o `published`. Controlla ogni riga con le regole del database: se anche una sola è errata non scrive nulla e ritorna `{ok:false, error:'validation', bad_rows, rows:[{row, errors}]}` (prime 50). Gli id già presenti vengono saltati.

## Redazione: materiali, quiz, catalogo, ruoli (patch 12)
- `create_material(p_env, p_title, p_subject_id, p_topic_id, p_format = 'scheda')`
- `update_material(p_env, p_mid, p_fields)` — `title, subject_id, topic_id, format, minutes, source, key_concepts, last_verified, next_review, sections, related`.
- `set_material_file(p_env, p_mid, p_path)` — collega il file caricato.
- `material_transition(p_env, p_mid, p_action)` — `submit, approve, publish, unpublish`.
- `save_quiz(p_env, p_quiz)` — crea o aggiorna un quiz in bozza.
- `set_quiz_status(p_env, p_zid, p_status)` — `published` o `draft`; la pubblicazione applica i controlli di `BL.quizChecks`, altrimenti `{ok:false, error:'checks_failed', failed:[...]}`.
- `tax_edit(p_env, p_kind, p_id, p_patch)` — solo amministratori; `p_kind`: `areas, subjects, topics, professional_profiles, entities`; `p_id` nullo crea una voce.
- `set_role(p_uid, p_role)` — solo amministratori; l'ultimo amministratore non può essere declassato (`last_admin`).

## Esempi

```js
const { data, error } = await supabase.rpc('start_session', {
  cfg: { env: 'demo', mode: 'exam', title: 'Simulazione', key: 'sim-1', count: 30, duration_min: 45 }
});
if (data?.ok) { /* data.session.items */ }

await supabase.rpc('save_session', { p_id: sessionId, p_answers: { q01: 2 }, p_current: 1 });
const { data: res } = await supabase.rpc('finish_session', { p_id: sessionId, p_reason: 'submitted' });
const { data: review } = await supabase.rpc('get_attempt_review', { p_attempt_id: sessionId });
```

Nota: `question_versions` non è più leggibile con `select *`; elencare le colonne oppure usare la vista `live_questions`.
L'id della sessione coincide con l'id del tentativo.
