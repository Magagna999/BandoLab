# BandoLab — Database e API

Schema per PostgreSQL / Supabase in `schema.sql`. Corrisponde ai modelli di `bandolab-core.js`.

## Principi
- **Ambienti separati**: ogni tabella di contenuto ha la colonna `env` (`demo` | `real`) nella chiave primaria. I dati demo non possono finire nel reale.
- **ID stabili**: le associazioni usano ID (`s-amm`, `q01`…), mai i nomi visualizzati.
- **Versioni**: `questions` punta a `current_version`; le modifiche creano righe nuove in `question_versions`. `attempt_items` conserva la versione usata.
- **Nessuna eliminazione automatica**: sospensione (`suspended`) e consolidamento (`merged_into`) invece di `DELETE`.
- **Permessi lato server**: RLS sulle letture, funzioni RPC `security definer` per le transizioni.
- **Punteggio**: `compute_score()` replica `BL.computeScore` (stessa formula, soglia 21 sul valore non arrotondato).

## Funzioni RPC da implementare
| Funzione | Ruolo | Sostituisce nel core |
|---|---|---|
| `start_session(cfg)` | utente | `BL.startSession` — sceglie le domande pubblicate, fissa le versioni e la `deadline` |
| `save_session(id, answers, current)` | utente | `BL.saveSession` — rifiuta salvataggi dopo la `deadline` |
| `finish_session(id, reason)` | utente | `BL.finishSession` — calcola il punteggio con `compute_score`, assegna XP, idempotente |
| `log_interruption(id, type)` | utente | `BL.logInterruption` |
| `abandon_session(id)` | utente | `BL.abandonSession` |
| `complete_material(mid)` | utente | `BL.completeMaterial` |
| `create_report(qid, v, reason, text)` | utente | `BL.report` |
| `create_question()` | editor, admin | `BL.createQuestion` |
| `update_draft(qid, fields)` | editor, admin | `BL.updateDraft` |
| `transition(qid, action, note)` | per azione | `BL.transition` — submit, approve, changes, reject, publish, newVersion, suspend, unsuspend, verify, reopen |
| `material_transition(mid, action)` | per azione | `BL.materialTransition` |
| `set_quiz_status(zid, status)` | reviewer, admin | pubblicazione quiz con i controlli di `BL.quizChecks` |
| `decide_duplicate(a, b, decision, note)` | reviewer, admin | `BL.decideDuplicate` |
| `tax_edit(kind, id, patch)` | admin | `BL.taxEdit` |
| `set_role(uid, role)` | admin | `BL.setRole` |
| `export_my_data()` | utente | esportazione dati (GDPR) |
| `request_account_deletion()` | utente | eliminazione account (GDPR) |

Ogni RPC che modifica contenuti scrive una riga in `audit_log`.

## Passi per il collegamento
1. Crea un progetto Supabase, esegui `schema.sql`.
2. Attiva il provider Google in Authentication (client ID e secret da Google Cloud).
3. Popola la tassonomia dell'ambiente `real` solo con contenuti revisionati.
4. In `bandolab-core.js` sostituisci `BL.commit` e le funzioni elencate con chiamate a `supabase.rpc(...)`.
5. Aggiungi test end-to-end sui flussi elencati in `BandoLab Test.dc.html`.
