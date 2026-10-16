# Guida Supabase per BandoLab (passo per passo)

Tempo: circa 30 minuti. Costo: zero (piano gratuito).

## PARTE A — Creare l'account e il progetto

1. Vai su **supabase.com** e clicca **Start your project**.
2. Clicca **Continue with GitHub** (hai già un account GitHub) e autorizza.
3. Se ti chiede di creare un'organizzazione: nome `BandoLab`, tipo **Personal**, piano **Free**. Clicca **Create organization**.
4. Clicca **New project** e compila:
   - **Name**: `bandolab`
   - **Database Password**: clicca **Generate a password**, poi **copiala e salvala** in un posto sicuro (Note del telefono, gestore password). Non ti servirà darmela.
   - **Region**: **West EU (Ireland)** oppure **Central EU (Frankfurt)** (i dati restano in Europa).
   - **Plan**: Free
5. Clicca **Create new project** e aspetta 1–2 minuti, finché non compare la schermata «Welcome to your new project».

## PARTE B — Creare le tabelle (lo schema)

1. Nel menu a sinistra clicca l'icona **SQL Editor** (simbolo `>_`).
2. Clicca **New query**.
3. Apri su GitHub (o dalla cartella dello zip) il file **db/schema.sql**. Selezionalo tutto (Ctrl+A / Cmd+A), copia (Ctrl+C / Cmd+C).
4. Incollalo nell'editor di Supabase (Ctrl+V / Cmd+V).
5. Clicca il pulsante verde **Run** (oppure Ctrl+Enter).
6. Risultato:
   - **«Success. No rows returned»**: tutto bene, vai alla Parte C.
   - **Errore in rosso**: fai uno screenshot, o copia il testo dell'errore, e mandamelo. Lo schema non è mai stato provato, quindi può servire una correzione. Non ripetere Run più volte: alcune tabelle sarebbero già create e compare «already exists».
7. Controlla: menu **Table Editor** (icona tabella). Devi vedere elenco di tabelle come `questions`, `attempts`, `materials`.

## PARTE C — Accesso con Google

1. Su **console.cloud.google.com** accedi con il tuo account Google.
2. In alto, menu progetti → **New project** → nome `BandoLab` → **Create**. Selezionalo.
3. Menu ☰ → **APIs & Services** → **OAuth consent screen** (o «Google Auth Platform»).
   - User type: **External** → Create.
   - App name: `BandoLab`. User support email e Developer email: la tua email. Salva.
4. Menu → **Credentials** → **Create credentials** → **OAuth client ID**.
   - Application type: **Web application**. Name: `BandoLab web`.
   - **Authorized redirect URIs** → **Add URI** e incolla l'indirizzo che trovi su Supabase: **Authentication → Sign In / Providers → Google**, riga «Callback URL (for OAuth)». Ha la forma `https://xxxx.supabase.co/auth/v1/callback`.
   - Clicca **Create**. Compaiono **Client ID** e **Client secret**: copiali.
5. Torna su Supabase: **Authentication → Sign In / Providers → Google**:
   - attiva **Enable Sign in with Google**
   - incolla **Client ID** e **Client secret**
   - **Save**.
6. Poi **Authentication → URL Configuration**:
   - **Site URL**: `https://magagna999.github.io/MySite/`
   - **Redirect URLs** → Add URL: `https://magagna999.github.io/MySite/**`
   - Save.

(Il Client secret non va dato a me né scritto su GitHub: resta solo dentro Supabase.)

## PARTE D — Cosa mandarmi

Su Supabase vai a **Project Settings** (ingranaggio in basso a sinistra) → **API** (o «API Keys»). Mandami **solo queste due cose**:

1. **Project URL**: `https://xxxxxxxx.supabase.co`
2. **anon public key**: stringa lunga che inizia con `eyJ...` (se vedi «publishable key» che inizia con `sb_publishable_`, va bene quella).

**Non mandarmi MAI:** la chiave **service_role** / **secret**, la password del database, il Client secret di Google.

L'URL e la chiave anon sono pensate per stare nel sito pubblico: la sicurezza la fanno le regole (RLS) dello schema.

## PARTE E — Dopo

Quando mi mandi i due dati e mi dici se la Parte B è andata a buon fine, collego il sito: login Google, salvataggio dei dati e caricamento dei PDF.
