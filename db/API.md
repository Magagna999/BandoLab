# BandoLab — Contratto delle funzioni RPC

Funzioni disponibili dopo le patch 07 e 08. Tutte richiedono un utente autenticato (`authenticated`);
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
