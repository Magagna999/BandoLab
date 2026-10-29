> **Chi riprende il lavoro (persone o IA): leggi prima [`HANDOFF.md`](HANDOFF.md).**

# BandoLab — prototipo interattivo

Prototipo ad alta fedeltà. **Non è pronto per la produzione.** Tutti i dati vivono nel `localStorage` del browser.

## Come esplorarlo
1. `BandoLab Landing.dc.html` — landing, quiz demo senza account, pagine legali predisposte.
2. «Inizia gratis» → accesso Google **simulato** → scegli ambiente (Demo / Reale) e account di prova:
   - Giulia Neri — nuovo utente (onboarding, dashboard vuota)
   - Marco Esposito — utente abituale (3 settimane di dati sintetici)
   - Sara Conti / Luca Ferri — editor · Paolo Ricci — revisore · Elena Marino — amministratore
3. `BandoLab App.dc.html` — area utente. `BandoLab Admin.dc.html` — area editoriale (il ruolo si cambia dall'intestazione).
4. `BandoLab Test.dc.html` — test automatici (punteggio + 25 scenari). Ripristinano i dati al termine.
5. Profilo → Prototipo: simula errore di salvataggio, ripristina dati demo, cambia ambiente, stato integrazioni.

## Architettura
- `bandolab-core.js` — logica condivisa, indipendente dalla UI:
  punteggio (`computeScore`, unica funzione), modelli dati con ID stabili, tassonomia, banca domande con versioni,
  store con commit/rollback, sessioni (timer basato su scadenza), statistiche, gamification, ricerca fuzzy,
  permessi per ruolo, workflow editoriale, segnalazioni, duplicati, controlli di pubblicazione quiz.
- Quattro Design Component (`.dc.html`): Landing, App, Admin, Test. Solo presentazione e stato di interfaccia.
- Ambienti `demo` e `real` separati in `state.data` e nei record utente (`uid@env`).

## Stato delle funzioni
**Implementate (nel browser):** punteggio e test; quiz demo; allenamento e simulazione; timer con consegna automatica e
ripresa dopo ricarica; revisione risposte; biblioteca, lettore con segnalibri e avanzamento; percorsi (salta, riordina,
riprendi); progressi con filtri e soglie di affidabilità; XP/livelli/badge con anti-ripetizione; ricerca; notifiche in-app;
preferenze e tema chiaro/scuro persistenti; onboarding saltabile; workflow Bozza → Revisione → Approvato → Pubblicato;
versionamento; segnalazioni e sospensione; verifiche normative; duplicati; tassonomia; ruoli; cronologia.

**Simulate:** accesso Google, persistenza, permessi (solo client), protezione del timer, esportazione (scarica i dati locali),
eliminazione account (dati locali), notifiche.

**Predisposte non collegate:** lettore/download PDF (nessun file caricato).

**Da sviluppare (richiedono backend/credenziali):** OAuth Google reale, database, API con autorizzazione server-side,
sessioni d'esame validate dal server, audit log immutabile, export/cancellazione GDPR reali, storage PDF.

## Database
Schema PostgreSQL/Supabase, patch 01–12 e funzioni RPC per sessioni, punteggio, soluzioni, area utente e redazione: vedi `db/README.md` e `db/API.md`.
Il database è attivo e le RPC sono testate (`db/tests/*.test.sql`), ma il sito è collegato solo in parte: la **Landing** ha l'accesso reale con Google (flusso PKCE, libreria supabase-js con controllo di integrità); **App e Admin** salvano ancora nel browser e vanno collegate una pagina alla volta, chiamando direttamente `bandolab-api.js` (nessuna copia locale dei dati, che resta solo per il demo anonimo). Per l'accesso reale servono Google e Supabase configurati (`GUIDA-SUPABASE.md`).

## Test automatici
`npm test` (Node 20 o successivo, nessuna dipendenza) esegue 83 unit test su `bandolab-core.js` e `bandolab-api.js`: punteggio, date, permessi, workflow editoriale, sessioni, XP, badge, statistiche, ricerca, duplicati, materiali e persistenza.
Il core viene caricato in un contesto isolato con un orologio finto (`test/helpers/core.js`), quindi i risultati sono ripetibili. La pagina `BandoLab Test.dc.html` resta per le prove nel browser.
I test servono da rete di sicurezza: il codice del core può essere riorganizzato finché `npm test` resta verde e l'API pubblica `BL.*` non cambia.

## Limiti noti
- Dati e permessi manipolabili dal browser: nessuna sicurezza reale.
- Il timer resiste alla ricarica ma non a modifiche di `localStorage` o dell'orologio di sistema.
- Domande e materiali demo sono sintetici, non ufficiali e non verificati.
- Accessibilità progettata (ruoli ARIA, focus visibile, tastiera nel quiz, riduzione animazioni) ma non certificata WCAG 2.2 AA.
- TypeScript non utilizzato: l'ambiente esegue JavaScript nel browser senza build. I modelli sono documentati nel core.

## Roadmap verso una prima versione reale
1. Repository React + TypeScript (Vite), tipi derivati dai modelli del core; porting di `bandolab-core` in moduli testati (Vitest).
2. Backend Supabase con OAuth Google, ruoli imposti lato server, RLS/policy per ambiente (database e RPC fatti; manca il collegamento del client).
3. Sessioni d'esame con scadenza decisa dal server e registrazione delle interruzioni (fatto lato database).
4. Workflow editoriale e audit log lato server; storage PDF.
5. Popolamento del catalogo reale solo con contenuti revisionati; test end-to-end e audit di accessibilità.
