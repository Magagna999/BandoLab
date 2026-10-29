# BandoLab — passaggio di consegne (HANDOFF)

Leggi questo file per primo se apri una nuova chat o se sei un'altra IA che riprende il lavoro.
Aggiornato il 29/10/2026, stato al commit `52a7971`. Il documento dettagliato (30 pagine, PDF) è del proprietario; questo file è la versione operativa.

## 1. Il progetto in breve
- BandoLab: piattaforma di preparazione a concorsi (quiz, materiali, percorsi, revisione errori, area redazione).
- Repo: `github.com/Magagna999/BandoLab` (ramo `main`). Proprietario: Luca (italiano).
- Backend: Supabase, progetto `ugvcorodqqvaomvhujre` (`https://ugvcorodqqvaomvhujre.supabase.co`). Chiave pubblica (publishable, può stare nel sito): `sb_publishable_Y3mgOj5jerQWXB2rq2T1nA_uBR_srR0`.
- Frontend: pagine `*.dc.html` (prototipo "Design Component"), logica condivisa in `bandolab-core.js`, livello API in `bandolab-api.js`.

## 2. Come lavorare con Luca (preferenze stabili)
- Rispondere in **italiano**, in modo **lineare e diretto**, **un passo alla volta**. Niente metodo socratico.
- **Commit commentati** (cosa e perché) e **GitHub sempre aggiornato** dopo ogni blocco di lavoro.
- Prima di cambiare il database: spiegare cosa si fa, ottenere l'ok. **Non applicare la patch 13 senza suo ok esplicito.**
- Mai chiedere o salvare chiavi segrete (service_role, password database, Client Secret di Google).

## 3. Stato
Fatto:
- Database: 31 tabelle, RLS su tutte (54 policy), 27 funzioni di servizio (RPC) con `search_path` fisso, patch 01–12 applicate, dati demo caricati (ambiente `demo`), `real` vuoto.
- API client: 41 metodi in `bandolab-api.js`, errori tradotti in italiano, accesso Google con flusso PKCE.
- Test: `npm test` → 83/83; test SQL su database reale in `db/tests/` (con rollback forzato).
- Landing: accesso Google reale collegato (`BandoLab Landing.dc.html`).
- Pulizia: rimossi gli accessi rapidi dall'Admin.

Non fatto (dettagli in `README.md` e nel PDF):
- **A carico di Luca:** progetto Google Cloud (22 passi), provider Google in Supabase, deploy su Vercel, Site URL e Redirect URLs in Supabase, protezione password compromesse (Auth), contenuti reali in Excel, testi legali.
- **Database:** RPC per segnalibri/progresso lettura, riordino/skip percorsi, profilo (nome/tema); poi patch 13; bucket Storage per i PDF; primo amministratore.
- **Pagine:** collegare App utente e Admin a `bandolab-api.js` (oggi usano ancora il core demo); test end-to-end, accessibilità, intestazioni di sicurezza Vercel, CI.

## 4. Regole architetturali (da non violare)
1. Le pagine parlano con il server **solo tramite `bandolab-api.js`**. Nessuna copia locale dei dati del server (la sincronizzazione con cache è stata scartata come meno sicura).
2. `bandolab-core.js` serve solo per demo anonimo e formattazione.
3. Le soluzioni (`correct`, `explanation`) non arrivano al browser prima del momento giusto: solo via RPC.
4. Tutte le scritture passano da RPC `security definer`; ogni modifica ai contenuti scrive una riga in `audit_log`.
5. Codici errore RPC: non autenticato `28000`, non autorizzato `42501`, dati non validi `22023`; esiti attesi come `{ok:false,error,why}`.
6. Un amministratore può essere autore e revisore dei propri contenuti (patch 09); editor e revisori no.
7. Ambienti `demo` e `real` separati dalla colonna `env`.

## 5. Procedure operative
- **Test JS:** `npm test` (Node ≥ 20, nessuna dipendenza).
- **Database:** la shell del workspace **non raggiunge Supabase**. Si usa lo strumento Supabase collegato (`apply_migration`, `execute_sql`, `get_advisors`, `list_migrations`). Le migrazioni registrate partono dalla `patch_06`; le patch 01–05 furono eseguite nell'editor SQL.
- **Nuova patch:** scrivere `db/patch-NN-nome.sql` con intestazione e riga `STATO`; applicarla; eseguire `get_advisors` (atteso: 0 errori, 27 avvisi noti sulle funzioni, più la protezione password); scrivere un test in `db/tests/` (blocchi `DO` con ruoli simulati e rollback forzato); aggiornare `db/README.md` e `db/API.md`; commit.
- **Nuova RPC:** aggiungere anche il wrapper in `bandolab-api.js` e un test in `test/api.test.js`.
- **Caricare domande da Excel:** `db/import/modello-domande.xlsx` → `python3 db/tools/excel-to-sql.py FILE.xlsx --author UUID [--env real] ...` → eseguire l'SQL (vedi `db/README.md`).
- **Browser di prova (Playwright):** dal workspace unpkg e i font sono bloccati dal proxy; React e Babel si servono da npm in locale. Non aggirare il proxy.

## 6. Patch 13 (in sospeso)
`db/patch-13-table-privileges.sql`: revoca i privilegi generali ad `anon` e `authenticated` e riconcede il minimo. **Non applicata.** Bloccherebbe le scritture dirette su `reading_progress`, `user_path_progress` e sul profilo, quindi prima servono le RPC di cui al punto 3. Decisione di Luca: applicare, applicare a pezzi o rinunciare.

## 7. Ordine consigliato dei prossimi passi
1. Luca: deploy Vercel; Google Cloud + provider Google in Supabase; Site URL/Redirect URLs.
2. Primo accesso con Google, poi promozione a admin con una riga SQL.
3. RPC per profilo, segnalibri, percorsi; poi patch 13.
4. Collegare App utente (poi Admin) a `bandolab-api.js`, un blocco alla volta con commit.
5. Storage PDF, contenuti reali, test end-to-end, sicurezza Vercel, CI.

## 8. Mappa dei file
- `README.md` — panoramica; `github.md` — registro sincronizzazioni; `GUIDA-SUPABASE.md` — guida iniziale (cita ancora GitHub Pages: da aggiornare con Vercel).
- `db/README.md` — patch e funzioni; `db/API.md` — contratto delle RPC.
- `db/tests/*.sql` — test sul database; `test/*.test.js` — test JS.
- `db/tools/` — generatore seed demo, convertitore Excel→SQL.
