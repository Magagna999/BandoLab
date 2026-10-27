/* BandoLab — livello API verso Supabase (area utente).
 *
 * Perché esiste: bandolab-core.js salva tutto nel browser (localStorage). Questo modulo fa le stesse operazioni
 * sul database, tramite le funzioni RPC descritte in db/API.md e le viste di sola lettura.
 *
 * Regole di questo modulo:
 *  - tutte le funzioni sono asincrone e NON sollevano eccezioni: ritornano sempre { ok: true, ... } oppure
 *    { ok: false, error: '<codice>', why: '<messaggio in italiano>' };
 *  - il server decide scadenze, punteggi e XP; il client li mostra soltanto;
 *  - le soluzioni arrivano solo da getQuestionFeedback e getAttemptReview.
 *
 * Uso nel browser (dopo aver caricato supabase-js):
 *   const api = BandoLabAPI.connect();            // usa URL e chiave pubblica del progetto
 *   await api.signInWithGoogle();
 *   const r = await api.startSession({ env: 'demo', mode: 'training', title: 'Prova', key: 'k1', count: 10 });
 *
 * Nei test si passa un client finto: BandoLabAPI.create({ client }).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.BandoLabAPI = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const PROJECT_URL = 'https://ugvcorodqqvaomvhujre.supabase.co';
  // Chiave pubblica (publishable): può stare nel codice del sito. La protezione dei dati è nelle regole RLS del database.
  const PUBLISHABLE_KEY = 'sb_publishable_Y3mgOj5jerQWXB2rq2T1nA_uBR_srR0';

  /* ---------- errori ---------- */
  const MESSAGES = {
    session_exists: 'Hai già una sessione aperta: riprendila o abbandonala prima di iniziarne un\'altra.',
    session_not_found: 'Sessione non trovata (potrebbe essere già stata chiusa).',
    insufficient: 'Non ci sono abbastanza domande per questa configurazione.',
    expired: 'Il tempo della simulazione è scaduto.',
    not_expired: 'La simulazione non è ancora scaduta.',
    not_available: 'La soluzione non è disponibile per questa modalità.',
    not_revealed: 'La soluzione di questa domanda non è stata ancora rivelata.',
    question_not_in_session: 'La domanda non fa parte della sessione.',
    attempt_not_found: 'Tentativo non trovato.',
    not_found: 'Contenuto non trovato.',
    not_authenticated: 'Devi accedere per continuare.',
    forbidden: 'Non sei autorizzato a questa azione.',
    invalid: 'Dati non validi.',
    network: 'Connessione al database non riuscita. Riprova.'
  };
  const PG_CODES = { '28000': 'not_authenticated', '42501': 'forbidden', '22023': 'invalid', 'PGRST301': 'not_authenticated' };

  const fail = (error, extra) => Object.assign({ ok: false, error, why: MESSAGES[error] || String(error) }, extra || {});

  /** Converte una risposta { data, error } di supabase-js in un risultato uniforme. */
  function fromRpc(res) {
    if (!res) return fail('network');
    if (res.error) {
      const code = PG_CODES[res.error.code] || (res.error.message && /permission denied/i.test(res.error.message) ? 'forbidden' : 'network');
      const out = fail(code);
      if (code === 'invalid' && res.error.message) out.why = res.error.message;
      return out;
    }
    const d = res.data;
    if (d && d.ok === false) return fail(d.error || 'invalid', d);
    return Object.assign({ ok: true }, d && typeof d === 'object' ? d : {});
  }

  /* ---------- conversioni riga → formato del core ---------- */
  const ms = t => (t ? Date.parse(t) : null);
  const fmt1 = n => (Math.round(n * 10) / 10).toFixed(1).replace('.', ',');

  function toScore(a) {
    if (a.n == null || a.score == null) return null;
    const score = Number(a.score);
    return { C: a.c, E: a.e, O: a.o, N: a.n, raw: Number(a.raw_score), score, display: fmt1(score), passed: !!a.passed };
  }
  function toAttempt(a) {
    return {
      id: a.id, mode: a.mode, title: a.title, key: a.quiz_key, status: a.status, reason: a.reason,
      startedAt: ms(a.started_at), finishedAt: ms(a.finished_at), durationSec: a.duration_sec,
      score: toScore(a), interruptions: a.interruptions || [], pathRef: a.path_ref || null
    };
  }
  function toSession(s, serverNow) {
    return {
      id: s.id, mode: s.mode, title: s.title, key: s.key || s.quiz_key, items: s.items || [],
      answers: s.answers || {}, revealed: s.revealed || {}, current: s.current != null ? s.current : (s.current_idx || 0),
      startedAt: ms(s.started_at), deadline: ms(s.deadline), pathRef: s.path_ref || null,
      // scarto tra l'orologio del server e quello del dispositivo: serve a mostrare il timer corretto
      clockSkew: serverNow ? ms(serverNow) - Date.now() : 0
    };
  }

  function create(opts) {
    const client = opts && opts.client;
    if (!client) throw new Error('BandoLabAPI.create: serve un client Supabase');

    /** Esegue una funzione asincrona e non lascia mai uscire eccezioni. */
    const safe = async fn => { try { return await fn(); } catch (e) { return fail('network', { detail: e && e.message }); } };
    const rpc = (name, args) => safe(async () => fromRpc(await client.rpc(name, args)));
    const select = (table, cols, f) => safe(async () => {
      let q = client.from(table).select(cols);
      if (f) q = f(q);
      const r = await q;
      if (r.error) return fromRpc(r);
      return { ok: true, rows: r.data || [] };
    });

    const api = {};

    /* ----- accesso ----- */
    api.signInWithGoogle = redirectTo => safe(async () => {
      const r = await client.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: redirectTo || (typeof location !== 'undefined' ? location.href.split('#')[0] : undefined) } });
      return r.error ? fail('network', { detail: r.error.message }) : { ok: true };
    });
    api.signOut = () => safe(async () => { const r = await client.auth.signOut(); return r.error ? fail('network') : { ok: true }; });
    /** Utente connesso (o null). */
    api.getUser = () => safe(async () => {
      const r = await client.auth.getSession();
      const u = r && r.data && r.data.session && r.data.session.user;
      return { ok: true, user: u ? { id: u.id, email: u.email } : null };
    });
    /** Riceve true/false a ogni cambio di accesso; ritorna la funzione per annullare l'iscrizione. */
    api.onAuthChange = cb => {
      const r = client.auth.onAuthStateChange((_event, session) => cb(session && session.user ? { id: session.user.id, email: session.user.email } : null));
      const sub = r && r.data && r.data.subscription;
      return () => { if (sub) sub.unsubscribe(); };
    };
    /** Profilo dell'utente (nome, ruolo, tema). Il profilo viene creato dal database al primo accesso. */
    api.getProfile = () => safe(async () => {
      const u = await api.getUser();
      if (!u.user) return fail('not_authenticated');
      const r = await select('profiles_user', 'id, display_name, email, role, theme', q => q.eq('id', u.user.id));
      if (!r.ok) return r;
      const row = r.rows[0];
      if (!row) return fail('not_found');
      return { ok: true, profile: { id: row.id, name: row.display_name, email: row.email, role: row.role, theme: row.theme } };
    });

    /* ----- sessioni di quiz (RPC) ----- */
    /** cfg: { env, mode, title, key, count, durationMin?, filter?, pathRef? } */
    api.startSession = cfg => safe(async () => {
      const args = {
        cfg: {
          env: cfg.env, mode: cfg.mode, title: cfg.title, key: cfg.key, count: cfg.count,
          duration_min: cfg.durationMin || null, filter: cfg.filter || {}, path_ref: cfg.pathRef || null
        }
      };
      const r = fromRpc(await client.rpc('start_session', args));
      if (!r.ok) return r;
      return { ok: true, prioritized: !!r.prioritized, session: toSession(r.session, r.session && r.session.server_now) };
    });
    /** patch: { answers?, revealed?, current? } */
    api.saveSession = (id, patch) => rpc('save_session', {
      p_id: id, p_answers: (patch && patch.answers) || {}, p_revealed: (patch && patch.revealed) || null,
      p_current: patch && patch.current != null ? patch.current : null
    });
    api.finishSession = (id, reason) => safe(async () => {
      const r = fromRpc(await client.rpc('finish_session', { p_id: id, p_reason: reason || 'submitted' }));
      if (!r.ok) return r;
      const a = r.attempt;
      return {
        ok: true, already: !!r.already, xp: r.xp || [],
        attempt: {
          id: a.id, mode: a.mode, title: a.title, status: a.status, reason: a.reason,
          startedAt: ms(a.started_at), finishedAt: ms(a.finished_at), durationSec: a.duration_sec,
          score: { C: a.c, E: a.e, O: a.o, N: a.n, raw: Number(a.raw), score: Number(a.score), display: a.display || fmt1(Number(a.score)), passed: !!a.passed }
        }
      };
    });
    api.logInterruption = (id, type) => rpc('log_interruption', { p_id: id, p_type: type });
    api.abandonSession = id => rpc('abandon_session', { p_id: id });

    /* ----- soluzioni (solo tramite RPC) ----- */
    api.getQuestionFeedback = (sessionId, qid) => rpc('get_question_feedback', { p_session_id: sessionId, p_qid: qid });
    api.getAttemptReview = attemptId => rpc('get_attempt_review', { p_attempt_id: attemptId });
    api.getQuestionVersionStaff = (env, qid, v) => rpc('get_question_version_staff', { p_env: env, p_qid: qid, p_v: v });

    /* ----- lettura dello stato dell'utente ----- */
    /** Sessione aperta, se esiste (per riprendere dopo una chiusura del browser). */
    api.getActiveSession = env => safe(async () => {
      const r = await select('quiz_sessions', 'id, mode, title, quiz_key, items, answers, revealed, current_idx, started_at, deadline, path_ref', q => q.eq('env', env));
      if (!r.ok) return r;
      return { ok: true, session: r.rows.length ? toSession(r.rows[0]) : null };
    });
    api.listAttempts = (env, limit) => safe(async () => {
      const r = await select('attempts', 'id, mode, title, quiz_key, status, reason, started_at, finished_at, duration_sec, c, e, o, n, raw_score, score, passed, interruptions, path_ref',
        q => q.eq('env', env).order('finished_at', { ascending: false }).limit(limit || 100));
      return r.ok ? { ok: true, attempts: r.rows.map(toAttempt) } : r;
    });
    api.listXp = env => safe(async () => {
      const r = await select('xp_events', 'amount, reason, at', q => q.eq('env', env).order('at', { ascending: true }));
      return r.ok ? { ok: true, xpLog: r.rows.map(x => ({ at: ms(x.at), amount: x.amount, reason: x.reason })) } : r;
    });
    api.listNotifications = env => safe(async () => {
      const r = await select('notifications', 'id, type, title, body, read_at, created_at', q => q.eq('env', env).order('created_at', { ascending: false }).limit(50));
      return r.ok ? { ok: true, notifications: r.rows.map(n => ({ id: n.id, type: n.type, title: n.title, body: n.body, at: ms(n.created_at), read: !!n.read_at })) } : r;
    });
    api.getPathProgress = env => safe(async () => {
      const r = await select('user_path_progress', 'path_id, step_order, step_status, updated_at', q => q.eq('env', env));
      if (!r.ok) return r;
      const paths = {};
      r.rows.forEach(p => { paths[p.path_id] = { order: p.step_order, status: p.step_status || {}, at: ms(p.updated_at) }; });
      return { ok: true, paths };
    });

    /* ----- catalogo pubblico (lettura) ----- */
    api.getTaxonomy = env => safe(async () => {
      const f = q => q.eq('env', env);
      const [areas, entities, subjects, topics, profiles] = await Promise.all([
        select('areas', 'id, name', f), select('entities', 'id, name, area_id', f), select('subjects', 'id, name', f),
        select('topics', 'id, name, subject_id', f), select('professional_profiles', 'id, name', f)]);
      const bad = [areas, entities, subjects, topics, profiles].find(x => !x.ok);
      if (bad) return bad;
      return {
        ok: true,
        taxonomy: {
          areas: areas.rows, subjects: subjects.rows,
          entities: entities.rows.map(e => ({ id: e.id, name: e.name, area: e.area_id })),
          topics: topics.rows.map(t => ({ id: t.id, name: t.name, subject: t.subject_id })),
          profiles: profiles.rows
        }
      };
    });
    api.listQuizzes = env => safe(async () => {
      const r = await select('quizzes', 'id, title, mode, subject_ids, topic_ids, question_count, duration_min', q => q.eq('env', env).eq('status', 'published'));
      return r.ok ? { ok: true, quizzes: r.rows.map(z => ({ id: z.id, title: z.title, mode: z.mode, count: z.question_count, durationMin: z.duration_min, filter: { subjects: z.subject_ids || undefined, topics: z.topic_ids || undefined } })) } : r;
    });
    api.listMaterials = env => safe(async () => {
      const [m, sec] = await Promise.all([
        select('materials', 'id, title, subject_id, topic_id, format, minutes, source, key_concepts, last_verified, next_review', q => q.eq('env', env).eq('status', 'published')),
        select('material_sections', 'material_id, id, position, title, body', q => q.eq('env', env).order('position', { ascending: true }))]);
      if (!m.ok) return m;
      if (!sec.ok) return sec;
      const by = {};
      sec.rows.forEach(s => { (by[s.material_id] = by[s.material_id] || []).push({ id: s.id, title: s.title, body: s.body }); });
      return {
        ok: true,
        materials: m.rows.map(x => ({ id: x.id, title: x.title, subject: x.subject_id, topic: x.topic_id, format: x.format, minutes: x.minutes, source: x.source, keyConcepts: x.key_concepts || [], lastVerified: x.last_verified, nextReview: x.next_review, sections: by[x.id] || [] }))
      };
    });
    api.listPaths = env => safe(async () => {
      const [p, st] = await Promise.all([
        select('study_paths', 'id, title, description, profile_id', q => q.eq('env', env).eq('status', 'published')),
        select('study_path_steps', 'path_id, id, position, type, title, material_id, quiz_id, subject_ids, topic_ids, question_count', q => q.eq('env', env).order('position', { ascending: true }))]);
      if (!p.ok) return p;
      if (!st.ok) return st;
      return {
        ok: true,
        paths: p.rows.map(x => ({
          id: x.id, title: x.title, description: x.description, profile: x.profile_id,
          steps: st.rows.filter(s => s.path_id === x.id).map(s => ({ id: s.id, type: s.type, title: s.title, ref: s.material_id || s.quiz_id || null, subjects: s.subject_ids, topics: s.topic_ids, count: s.question_count }))
        }))
      };
    });

    return api;
  }

  /** Crea il client Supabase nel browser (richiede supabase-js già caricato) e ritorna l'API. */
  function connect(opts) {
    opts = opts || {};
    const lib = opts.lib || (typeof window !== 'undefined' && window.supabase);
    if (!lib || !lib.createClient) throw new Error('supabase-js non è stato caricato');
    const client = lib.createClient(opts.url || PROJECT_URL, opts.key || PUBLISHABLE_KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
    return create({ client });
  }

  return { create, connect, fromRpc, MESSAGES, PROJECT_URL, PUBLISHABLE_KEY };
});
