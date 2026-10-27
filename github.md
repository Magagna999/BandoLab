repo: Magagna999/BandoLab
branch: main

## Last sync
date: 2026-10-27T15:00:00Z

### Updated in this project
- Revisione del database: patch 06 (policy più restrittive), 07 (RPC per sessioni, punteggio, XP), 08 (risposte corrette nascoste al client)
- Test eseguito sul database reale: 39 controlli (T01–T33) tutti ok, nessun dato lasciato
- Documentazione: db/API.md (contratto RPC), db/README.md aggiornato, README.md aggiornato
- Security Advisor: 8 avvisi attesi per le funzioni security definer, nessun errore
- Dati demo caricati nel database (db/seed-demo.sql: 53 domande, 8 materiali, 5 quiz, 2 percorsi); generatore in db/tools/
- Corretto il testo di q41 nel core (troppo corto per il vincolo del database)
- Riferimenti MySite sostituiti con BandoLab
- Import domande da Excel: modello db/import/modello-domande.xlsx e controllo/conversione db/tools/excel-to-sql.py (provato sul database, annullato)
- Patch 09: l'amministratore può essere autore e revisore (trigger nel database + regola in bandolab-core.js); editor e revisori restano vincolati
- Il sito non è ancora collegato al database (salva ancora nel browser); prossimo passo: bandolab-api.js

## Screen map
| Schermata | File nel repository |
|---|---|
| Landing + quiz demo + accesso | BandoLab Landing.dc.html, bandolab-core.js |
| App utente | BandoLab App.dc.html, bandolab-core.js |
| Area amministrativa | BandoLab Admin.dc.html, bandolab-core.js |
| Test automatici | BandoLab Test.dc.html, bandolab-core.js |
| Pagina iniziale (redirect) | index.html |
| Database | db/schema.sql, db/patch-01..09, db/seed-demo.sql, db/import/, db/tools/, db/API.md, db/README.md, db/tests/, GUIDA-SUPABASE.md |

## Sync history
- 2026-10-27T17:30:00Z — patch 09, admin autore e revisore
- 2026-10-27T17:00:00Z — modello Excel e importatore delle domande
- 2026-10-27T16:00:00Z — seed demo nel database, generatore, riferimenti BandoLab
- 2026-10-27T15:00:00Z — patch 06–08, RPC sessioni, test sul database, documentazione API
- 2026-10-16T12:20:00Z — database Supabase creato: schema + patch 01-05
- 2026-10-16T11:19:11Z — importazione materiali, accesso rapido admin, guida Supabase
- 2026-10-12T10:05:54Z — schema DB, 15 domande demo, index.html
- 2026-10-12T09:31:24Z — prima pubblicazione (8 file)
