'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const BandoLabAPI = require('../bandolab-api.js');
const { makeFake } = require('./helpers/fake-supabase');

const setup = () => { const fake = makeFake(); return { fake, api: BandoLabAPI.create({ client: fake }) }; };
const lastCall = f => f.calls[f.calls.length - 1];

test('create: richiede un client', () => {
  assert.throws(() => BandoLabAPI.create({}), /client/);
});

test('fromRpc: esiti normali, errori applicativi e codici Postgres', () => {
  const { fromRpc } = BandoLabAPI;
  assert.deepEqual(fromRpc({ data: { ok: true, x: 1 }, error: null }), { ok: true, x: 1 });
  const app = fromRpc({ data: { ok: false, error: 'session_exists' }, error: null });
  assert.equal(app.ok, false); assert.equal(app.error, 'session_exists'); assert.match(app.why, /sessione aperta/);
  assert.equal(fromRpc({ data: null, error: { code: '42501', message: 'x' } }).error, 'forbidden');
  assert.equal(fromRpc({ data: null, error: { code: '28000', message: 'x' } }).error, 'not_authenticated');
  const inv = fromRpc({ data: null, error: { code: '22023', message: 'Risposta fuori scala' } });
  assert.equal(inv.error, 'invalid'); assert.equal(inv.why, 'Risposta fuori scala');
  assert.equal(fromRpc({ data: null, error: { code: 'XX', message: 'permission denied for function x' } }).error, 'forbidden');
  assert.equal(fromRpc({ data: null, error: { code: 'XX', message: 'boom' } }).error, 'network');
  assert.equal(fromRpc(null).error, 'network');
});

test('startSession: traduce i parametri e converte la sessione nel formato del core', async () => {
  const { fake, api } = setup();
  fake.rpcResults.start_session = { data: { ok: true, prioritized: true, session: { id: 's1', mode: 'exam', title: 'Sim', key: 'k', items: [{ qid: 'q01', v: 1 }], answers: {}, revealed: {}, current: 0, started_at: '2026-10-27T10:00:00Z', deadline: '2026-10-27T10:45:00Z', server_now: '2026-10-27T10:00:05Z' } }, error: null };
  const r = await api.startSession({ env: 'demo', mode: 'exam', title: 'Sim', key: 'k', count: 30, durationMin: 45, filter: { subjects: ['s-amm'] } });
  assert.deepEqual(lastCall(fake).args.cfg, { env: 'demo', mode: 'exam', title: 'Sim', key: 'k', count: 30, duration_min: 45, filter: { subjects: ['s-amm'] }, path_ref: null });
  assert.equal(r.ok, true); assert.equal(r.prioritized, true);
  assert.equal(r.session.id, 's1');
  assert.equal(r.session.deadline - r.session.startedAt, 45 * 60e3);
  assert.equal(typeof r.session.clockSkew, 'number');
  assert.equal(r.session.key, 'k');
});

test('startSession: errori del server arrivano come risultato, senza eccezioni', async () => {
  const { fake, api } = setup();
  fake.rpcResults.start_session = { data: { ok: false, error: 'insufficient', available: 7 }, error: null };
  const r = await api.startSession({ env: 'demo', mode: 'training', title: 't', key: 'k', count: 50 });
  assert.equal(r.ok, false); assert.equal(r.error, 'insufficient'); assert.equal(r.available, 7);
  fake.rpcResults.start_session = new Error('rete assente');
  const n = await api.startSession({ env: 'demo', mode: 'training', title: 't', key: 'k', count: 5 });
  assert.equal(n.ok, false); assert.equal(n.error, 'network'); assert.equal(n.detail, 'rete assente');
});

test('saveSession: parametri e valori di default', async () => {
  const { fake, api } = setup();
  fake.rpcResults.save_session = { data: { ok: true }, error: null };
  await api.saveSession('s1', { answers: { q01: 2 }, current: 3 });
  assert.deepEqual(lastCall(fake).args, { p_id: 's1', p_answers: { q01: 2 }, p_revealed: null, p_current: 3 });
  await api.saveSession('s1', { revealed: { q01: true } });
  assert.deepEqual(lastCall(fake).args, { p_id: 's1', p_answers: {}, p_revealed: { q01: true }, p_current: null });
  await api.saveSession('s1', { current: 0 });
  assert.equal(lastCall(fake).args.p_current, 0); // 0 è un valore valido, non "assente"
  fake.rpcResults.save_session = { data: { ok: false, error: 'expired' }, error: null };
  assert.equal((await api.saveSession('s1', {})).error, 'expired');
});

test('finishSession: converte tentativo e punteggio, gestisce già consegnata', async () => {
  const { fake, api } = setup();
  fake.rpcResults.finish_session = { data: { ok: true, already: false, xp: [{ amount: 16, reason: 'Quiz completato' }], attempt: { id: 'a1', mode: 'training', title: 'T', status: 'completed', reason: 'submitted', started_at: '2026-10-27T10:00:00Z', finished_at: '2026-10-27T10:01:30Z', duration_sec: 90, c: 6, e: 3, o: 1, n: 10, raw: '4.25', score: '12.7500', display: '12,8', passed: false } }, error: null };
  const r = await api.finishSession('s1');
  assert.deepEqual(lastCall(fake).args, { p_id: 's1', p_reason: 'submitted' });
  assert.equal(r.ok, true);
  assert.equal(r.attempt.durationSec, 90);
  assert.deepEqual(r.attempt.score, { C: 6, E: 3, O: 1, N: 10, raw: 4.25, score: 12.75, display: '12,8', passed: false });
  assert.equal(r.xp[0].amount, 16);
  await api.finishSession('s1', 'timeout');
  assert.equal(lastCall(fake).args.p_reason, 'timeout');
  fake.rpcResults.finish_session = { data: { ok: false, error: 'not_expired' }, error: null };
  assert.equal((await api.finishSession('s1', 'timeout')).error, 'not_expired');
});

test('interruzioni, abbandono e soluzioni usano le RPC corrette', async () => {
  const { fake, api } = setup();
  ['log_interruption', 'abandon_session', 'get_question_feedback', 'get_attempt_review', 'get_question_version_staff']
    .forEach(n => { fake.rpcResults[n] = { data: { ok: true }, error: null }; });
  await api.logInterruption('s1', 'blur');
  assert.deepEqual(lastCall(fake), { type: 'rpc', name: 'log_interruption', args: { p_id: 's1', p_type: 'blur' } });
  await api.abandonSession('s1');
  assert.equal(lastCall(fake).name, 'abandon_session');
  await api.getQuestionFeedback('s1', 'q01');
  assert.deepEqual(lastCall(fake).args, { p_session_id: 's1', p_qid: 'q01' });
  await api.getAttemptReview('a1');
  assert.deepEqual(lastCall(fake).args, { p_attempt_id: 'a1' });
  await api.getQuestionVersionStaff('demo', 'q01', 1);
  assert.deepEqual(lastCall(fake).args, { p_env: 'demo', p_qid: 'q01', p_v: 1 });
  fake.rpcResults.get_question_feedback = { data: { ok: false, error: 'not_revealed' }, error: null };
  assert.equal((await api.getQuestionFeedback('s1', 'q02')).error, 'not_revealed');
  fake.rpcResults.get_question_version_staff = { data: null, error: { code: '42501', message: 'x' } };
  assert.equal((await api.getQuestionVersionStaff('demo', 'q01', 1)).error, 'forbidden');
});

test('accesso: Google, uscita, utente corrente, cambi di stato', async () => {
  const { fake, api } = setup();
  assert.equal((await api.signInWithGoogle('https://example.org/app')).ok, true);
  assert.deepEqual(fake.oauth, { provider: 'google', options: { redirectTo: 'https://example.org/app' } });
  assert.deepEqual((await api.getUser()).user, null);
  fake.session = { user: { id: 'u1', email: 'a@b.it' } };
  assert.deepEqual((await api.getUser()).user, { id: 'u1', email: 'a@b.it' });
  const seen = [];
  const off = api.onAuthChange(u => seen.push(u));
  fake.authListeners.forEach(cb => cb('SIGNED_IN', fake.session));
  fake.authListeners.forEach(cb => cb('SIGNED_OUT', null));
  assert.deepEqual(seen, [{ id: 'u1', email: 'a@b.it' }, null]);
  off();
  assert.equal(fake.authListeners.length, 0);
  assert.equal((await api.signOut()).ok, true);
  assert.equal(fake.signedOut, true);
});

test('getProfile: richiede accesso, legge il profilo dell\'utente', async () => {
  const { fake, api } = setup();
  assert.equal((await api.getProfile()).error, 'not_authenticated');
  fake.session = { user: { id: 'u1', email: 'a@b.it' } };
  fake.tables.profiles_user = [{ id: 'u2', display_name: 'Altro', email: 'x', role: 'admin', theme: 'dark' }, { id: 'u1', display_name: 'Luca', email: 'a@b.it', role: 'user', theme: 'light' }];
  const r = await api.getProfile();
  assert.deepEqual(r.profile, { id: 'u1', name: 'Luca', email: 'a@b.it', role: 'user', theme: 'light' });
  fake.tables.profiles_user = [];
  assert.equal((await api.getProfile()).error, 'not_found');
});

test('listAttempts: converte le righe nel formato del core, filtra per ambiente', async () => {
  const { fake, api } = setup();
  fake.tables.attempts = [
    { env: 'demo', id: 'a1', mode: 'exam', title: 'Sim', quiz_key: 'k', status: 'completed', reason: 'submitted', started_at: '2026-10-27T10:00:00Z', finished_at: '2026-10-27T10:30:00Z', duration_sec: 1800, c: 20, e: 6, o: 4, n: 30, raw_score: '16.00', score: '16.0000', passed: false, interruptions: [], path_ref: null },
    { env: 'demo', id: 'a2', mode: 'training', title: 'Ab', quiz_key: 'k2', status: 'abandoned', reason: 'abandoned', started_at: '2026-10-27T11:00:00Z', finished_at: '2026-10-27T11:02:00Z', duration_sec: 120, c: null, e: null, o: null, n: null, raw_score: null, score: null, passed: null, interruptions: [{ type: 'x' }], path_ref: null },
    { env: 'real', id: 'a3', mode: 'training', title: 'R', quiz_key: 'k', status: 'completed', reason: 'submitted', started_at: '2026-10-27T10:00:00Z', finished_at: '2026-10-27T10:30:00Z', duration_sec: 10, c: 1, e: 0, o: 0, n: 1, raw_score: '1', score: '30', passed: true, interruptions: [], path_ref: null }];
  const r = await api.listAttempts('demo');
  assert.equal(r.attempts.length, 2);
  assert.equal(r.attempts[0].score.display, '16,0');
  assert.equal(r.attempts[0].finishedAt, Date.parse('2026-10-27T10:30:00Z'));
  assert.equal(r.attempts[1].score, null);
  assert.equal(r.attempts[1].interruptions.length, 1);
});

test('letture: errori del database diventano risultati, mai eccezioni', async () => {
  const { fake, api } = setup();
  fake.tableErrors.attempts = { code: '42501', message: 'permission denied for table attempts' };
  const r = await api.listAttempts('demo');
  assert.equal(r.ok, false); assert.equal(r.error, 'forbidden');
});

test('xp, notifiche, percorsi, sessione attiva', async () => {
  const { fake, api } = setup();
  fake.tables.xp_events = [{ env: 'demo', amount: 10, reason: 'Quiz', at: '2026-10-27T10:00:00Z' }];
  fake.tables.notifications = [{ env: 'demo', id: 'n1', type: 'progress', title: 'T', body: 'B', read_at: null, created_at: '2026-10-27T10:00:00Z' }, { env: 'demo', id: 'n2', type: 'content', title: 'T', body: 'B', read_at: '2026-10-27T11:00:00Z', created_at: '2026-10-27T10:00:00Z' }];
  fake.tables.user_path_progress = [{ env: 'demo', path_id: 'p1', step_order: null, step_status: { s1: 'done' }, updated_at: '2026-10-27T10:00:00Z' }];
  fake.tables.quiz_sessions = [{ env: 'demo', id: 's9', mode: 'training', title: 'T', quiz_key: 'k', items: [{ qid: 'q1', v: 1 }], answers: { q1: 1 }, revealed: {}, current_idx: 4, started_at: '2026-10-27T10:00:00Z', deadline: null, path_ref: null }];
  assert.deepEqual((await api.listXp('demo')).xpLog, [{ at: Date.parse('2026-10-27T10:00:00Z'), amount: 10, reason: 'Quiz' }]);
  const n = (await api.listNotifications('demo')).notifications;
  assert.deepEqual(n.map(x => x.read), [false, true]);
  const p = (await api.getPathProgress('demo')).paths;
  assert.equal(p.p1.status.s1, 'done');
  const s = (await api.getActiveSession('demo')).session;
  assert.equal(s.id, 's9'); assert.equal(s.current, 4); assert.equal(s.deadline, null);
  assert.equal((await api.getActiveSession('real')).session, null);
});

test('catalogo: tassonomia, quiz, materiali con sezioni ordinate, percorsi con passi', async () => {
  const { fake, api } = setup();
  Object.assign(fake.tables, {
    areas: [{ env: 'demo', id: 'a1', name: 'Area' }], subjects: [{ env: 'demo', id: 's1', name: 'Materia' }],
    entities: [{ env: 'demo', id: 'e1', name: 'Ente', area_id: 'a1' }], topics: [{ env: 'demo', id: 't1', name: 'Arg', subject_id: 's1' }],
    professional_profiles: [{ env: 'demo', id: 'p1', name: 'Profilo' }],
    quizzes: [{ env: 'demo', status: 'published', id: 'z1', title: 'Q', mode: 'exam', subject_ids: ['s1'], topic_ids: null, question_count: 10, duration_min: 20 }, { env: 'demo', status: 'draft', id: 'z2', title: 'Bozza', mode: 'training', subject_ids: null, topic_ids: null, question_count: 5, duration_min: null }],
    materials: [{ env: 'demo', status: 'published', id: 'm1', title: 'Mat', subject_id: 's1', topic_id: 't1', format: 'scheda', minutes: 5, source: 'F', key_concepts: ['a'], last_verified: '2026-01-01', next_review: '2027-01-01' }],
    material_sections: [{ env: 'demo', material_id: 'm1', id: 'x1', position: 1, title: 'Sez', body: 'Corpo' }],
    study_paths: [{ env: 'demo', status: 'published', id: 'pp1', title: 'Percorso', description: 'd', profile_id: 'p1' }],
    study_path_steps: [{ env: 'demo', path_id: 'pp1', id: 'st1', position: 1, type: 'material', title: 'Leggi', material_id: 'm1', quiz_id: null, subject_ids: null, topic_ids: null, question_count: null }, { env: 'demo', path_id: 'altro', id: 'st9', position: 1, type: 'quiz', title: 'X', material_id: null, quiz_id: 'z1', subject_ids: null, topic_ids: null, question_count: null }]
  });
  const t = (await api.getTaxonomy('demo')).taxonomy;
  assert.deepEqual(t.entities, [{ id: 'e1', name: 'Ente', area: 'a1' }]);
  assert.deepEqual(t.topics, [{ id: 't1', name: 'Arg', subject: 's1' }]);
  const z = (await api.listQuizzes('demo')).quizzes;
  assert.equal(z.length, 1); assert.equal(z[0].count, 10); assert.deepEqual(z[0].filter, { subjects: ['s1'], topics: undefined });
  const m = (await api.listMaterials('demo')).materials[0];
  assert.equal(m.sections[0].body, 'Corpo'); assert.deepEqual(m.keyConcepts, ['a']);
  const p = (await api.listPaths('demo')).paths;
  assert.equal(p.length, 1); assert.equal(p[0].steps.length, 1); assert.equal(p[0].steps[0].ref, 'm1');
});

test('connect: usa supabase-js con URL e chiave del progetto', () => {
  let args;
  const lib = { createClient: (u, k, o) => { args = [u, k, o]; return makeFake(); } };
  const api = BandoLabAPI.connect({ lib });
  assert.equal(args[0], BandoLabAPI.PROJECT_URL);
  assert.match(args[1], /^sb_publishable_/);
  assert.equal(typeof api.startSession, 'function');
  assert.throws(() => BandoLabAPI.connect({ lib: {} }), /supabase-js/);
});
