// Genera db/seed-demo.sql dai dati demo di bandolab-core.js.
// Uso: node db/tools/generate-demo-seed.js   (dalla radice del repository)
// Il seed carica SOLO l'ambiente "demo". È idempotente (on conflict do nothing).
const fs = require('fs'), path = require('path');
global.window = global;
global.localStorage = { _d: {}, getItem(k) { return this._d[k] ?? null; }, setItem(k, v) { this._d[k] = v; }, removeItem(k) { delete this._d[k]; } };
global.document = { documentElement: { setAttribute() {}, style: {}, dataset: {} }, addEventListener() {}, querySelector() { return null; } };
global.matchMedia = () => ({ matches: false, addEventListener() {} });
global.addEventListener = () => {};
const root = path.join(__dirname, '..', '..');
(0, eval)(fs.readFileSync(path.join(root, 'bandolab-core.js'), 'utf8'));
const S = global.BL.load();
const D = S.data.demo || global.BL.bank('demo');


const out = [];
const iso = ms => ms == null ? null : new Date(ms).toISOString();
// Ogni tabella è caricata con un'unica istruzione: le righe sono un array JSON letto da jsonb_populate_recordset.
function load(table, rows) {
  if (!rows.length) return;
  const cols = [...new Set(rows.flatMap(r => Object.keys(r)))];
  const list = cols.join(', ');
  out.push(`insert into ${table} (${list}) select ${list} from jsonb_populate_recordset(null::${table}, $j$${JSON.stringify(rows)}$j$::jsonb) on conflict do nothing;`);
}
const env = 'demo';
const staff = [
  ['u-ed',  '00000000-0000-4000-8000-0000000000e1', 'editor'],
  ['u-ed2', '00000000-0000-4000-8000-0000000000e2', 'editor'],
  ['u-rev', '00000000-0000-4000-8000-0000000000a1', 'reviewer']
];
const UID = Object.fromEntries(staff.map(s => [s[0], s[1]]));
out.push("-- BandoLab — seed dell'ambiente DEMO. File generato da db/tools/generate-demo-seed.js: non modificare a mano.");
out.push('-- Crea 3 utenti di redazione fittizi (editor, editor, revisore) senza accesso possibile, poi tassonomia, domande, materiali, quiz e percorsi.');
// Utenti redazione fittizi (nessuna password, email @example.com). Il trigger handle_new_user crea il profilo.
const users = staff.map(([id, uuid]) => { const u = (S.users || []).find(x => x.id === id) || { name: id, email: id + '@example.com' }; return { id: uuid, instance_id: '00000000-0000-0000-0000-000000000000', aud: 'authenticated', role: 'authenticated', email: u.email, raw_user_meta_data: { full_name: u.name, demo_staff: true }, created_at: new Date().toISOString(), updated_at: new Date().toISOString() }; });
load('auth.users', users);
for (const [, uuid, role] of staff) out.push(`update public.profiles_user set role = '${role}'::role_t where id = '${uuid}'::uuid;`);
const T = D.taxonomy;
load('areas', T.areas.map(a => ({ id: a.id, env, name: a.name })));
load('entities', T.entities.map(e => ({ id: e.id, env, name: e.name, area_id: e.area })));
load('subjects', T.subjects.map(x => ({ id: x.id, env, name: x.name })));
load('topics', T.topics.map(t => ({ id: t.id, env, name: t.name, subject_id: t.subject })));
load('professional_profiles', T.profiles.map(p => ({ id: p.id, env, name: p.name })));
load('profile_entities', T.profiles.flatMap(p => (p.entities || []).map(e => ({ env, profile_id: p.id, entity_id: e }))));
load('profile_subjects', T.profiles.flatMap(p => (p.subjects || []).map(s => ({ env, profile_id: p.id, subject_id: s }))));
// Domande: righe, poi versioni (a gruppi), poi versione corrente
load('questions', D.questions.map(x => ({ id: x.id, env, suspended: !!x.suspended, suspend_note: x.suspended ? (x.suspendNote || 'Sospesa') : null, merged_into: x.mergedInto || null })));
const vers = D.questions.flatMap(x => x.versions.map(v => {
  const pub = ['published', 'superseded', 'approved'].includes(v.status);
  return { env, question_id: x.id, v: v.v, status: v.status, text: v.text, options: v.options, correct: v.correct, explanation: v.explanation || '', subject_id: v.subject, topic_id: v.topic, difficulty: v.difficulty, source: v.source || '', source_url: v.sourceUrl || null, last_verified: v.lastVerified || null, next_review: v.nextReview || null, author_id: UID[v.author], reviewer_id: v.reviewer ? UID[v.reviewer] : null, review_note: v.reviewNote || null, change_note: v.note || null, created_at: iso(v.createdAt), approved_at: pub ? iso(v.publishedAt || v.createdAt) : null, published_at: v.status === 'published' ? iso(v.publishedAt) : null };
}));
for (let i = 0; i < vers.length; i += 20) load('question_versions', vers.slice(i, i + 20));
const cur = D.questions.filter(x => x.current != null).map(x => x.id);
out.push(`update questions set current_version = 1 where env = 'demo' and id in (${cur.map(i => "'" + i + "'").join(',')});`);
load('question_profiles', D.questions.flatMap(x => { const v = x.versions.find(v => v.v === (x.current || x.versions[x.versions.length - 1].v)); return ((v && v.profiles) || []).map(p => ({ env, question_id: x.id, profile_id: p })); }));
// Materiali: i PDF non hanno ancora un file nello storage e il vincolo del database impedisce di pubblicarli, quindi restano in bozza.
load('materials', D.materials.map(m => ({ id: m.id, env, title: m.title, subject_id: m.subject, topic_id: m.topic, format: m.format, status: m.format !== 'scheda' && m.status === 'published' ? 'draft' : m.status, minutes: m.minutes, source: m.source || '', key_concepts: m.keyConcepts || [], last_verified: m.lastVerified, next_review: m.nextReview, author_id: UID[m.author] })));
load('material_sections', D.materials.flatMap(m => (m.sections || []).map((s, i) => ({ env, material_id: m.id, id: s.id, position: i + 1, title: s.title, body: s.body }))));
load('material_related', D.materials.flatMap(m => (m.related || []).map(r => ({ env, material_id: m.id, related_id: r }))));
load('quizzes', D.quizzes.map(z => ({ id: z.id, env, title: z.title, mode: z.mode, subject_ids: (z.filter && z.filter.subjects) || null, topic_ids: (z.filter && z.filter.topics) || null, question_count: z.count, duration_min: z.durationMin || null, status: z.status })));
load('study_paths', D.paths.map(p => ({ id: p.id, env, title: p.title, description: p.desc, profile_id: p.profile, status: p.status || 'published' })));
load('study_path_steps', D.paths.flatMap(p => p.steps.map((s, i) => ({ env, path_id: p.id, id: s.id, position: i + 1, type: s.type, title: s.title, material_id: s.type === 'material' ? s.ref : null, quiz_id: s.type === 'exam' ? s.quiz : null, subject_ids: (s.filter && s.filter.subjects) || null, topic_ids: (s.filter && s.filter.topics) || null, question_count: s.count || null }))));
fs.writeFileSync(path.join(root, 'db', 'seed-demo.sql'), out.join('\n') + '\n');
console.log('istruzioni:', out.length, '- domande:', D.questions.length, '- materiali:', D.materials.length);
