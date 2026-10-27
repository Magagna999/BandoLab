/* BandoLab core — logica condivisa (dati, punteggio, sessioni, workflow, permessi).
   Prototipo: persistenza su localStorage del browser. Nessun backend, nessuna sicurezza server-side. */
(function () {
'use strict';
const BL = {};
const DAY = 864e5;
const KEY = 'bandolab.state.v1';
const DEBUG_KEY = 'bandolab.debug';
const clone = o => JSON.parse(JSON.stringify(o));
const iso = t => new Date(t).toISOString().slice(0, 10);
const todayISO = () => iso(Date.now());
const addDays = (d, n) => iso(new Date(d + 'T12:00:00').getTime() + n * DAY);
BL.iso = iso; BL.todayISO = todayISO; BL.addDays = addDays; BL.DAY = DAY;
BL.fmt1 = n => (Math.round(n * 10) / 10).toFixed(1).replace('.', ',');
BL.pct = n => Math.round(n * 100) + '%';
BL.fmtDate = d => d ? new Date(typeof d === 'string' && d.length === 10 ? d + 'T12:00:00' : d).toLocaleDateString('it-IT', { day: 'numeric', month: 'short', year: 'numeric' }) : '—';
BL.fmtDateTime = d => new Date(d).toLocaleString('it-IT', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
BL.fmtDur = s => { s = Math.max(0, Math.round(s)); const m = Math.floor(s / 60), r = s % 60; return m + ':' + String(r).padStart(2, '0'); };
BL.rel = t => { const d = Math.floor((Date.now() - t) / DAY); return d <= 0 ? 'oggi' : d === 1 ? 'ieri' : d + ' giorni fa'; };

/* ---------- PUNTEGGIO (unica funzione condivisa) ---------- */
BL.SCORING = Object.freeze({ correct: 1, wrong: -0.5, omitted: -0.25, scale: 30, pass: 21 });
BL.computeScore = function (C, E, O, N) {
  if ([C, E, O, N].some(x => !Number.isInteger(x) || x < 0)) throw new Error('Valori non validi');
  if (C + E + O !== N) throw new Error('C + E + O deve essere uguale a N');
  if (N === 0) return { C, E, O, N, raw: 0, score: 0, display: '0,0', passed: false, empty: true };
  const raw = C - 0.5 * E - 0.25 * O;
  const score = Math.max(0, Math.min(30, 30 * raw / N));
  return { C, E, O, N, raw, score, display: BL.fmt1(score), passed: score >= BL.SCORING.pass, empty: false };
};
BL.scoreItems = items => {
  const C = items.filter(i => i.answer != null && i.correct).length;
  const O = items.filter(i => i.answer == null).length;
  return BL.computeScore(C, items.length - C - O, O, items.length);
};
BL.SCORE_TESTS = [
  { name: 'Quiz senza domande', in: [0, 0, 0, 0], expect: { score: 0, passed: false } },
  { name: 'Tutte le risposte corrette', in: [10, 0, 0, 10], expect: { score: 30, passed: true } },
  { name: 'Tutte errate (limite inferiore 0)', in: [0, 10, 0, 10], expect: { score: 0, raw: -5, passed: false } },
  { name: 'Tutte omesse (limite inferiore 0)', in: [0, 0, 10, 10], expect: { score: 0, raw: -2.5 } },
  { name: 'Caso misto', in: [3, 1, 1, 5], expect: { raw: 2.25, score: 13.5, display: '13,5' } },
  { name: 'Soglia esatta 21/30', in: [16, 4, 0, 20], expect: { score: 21, passed: true } },
  { name: 'Mostra 21,0 ma sotto soglia (esito su valore non arrotondato)', in: [130, 5, 35, 170], expect: { display: '21,0', passed: false } },
  { name: 'Grezzo negativo con risposte miste', in: [1, 4, 5, 10], expect: { score: 0 } },
  { name: 'Valori incoerenti', in: [3, 3, 3, 5], expectThrow: true },
  { name: 'Valori non interi', in: [1.5, 0, 0, 1.5], expectThrow: true }
];
BL.runScoreTests = () => BL.SCORE_TESTS.map(t => {
  try {
    const r = BL.computeScore(...t.in);
    if (t.expectThrow) return { name: t.name, pass: false, detail: 'Nessun errore sollevato' };
    const bad = Object.entries(t.expect).filter(([k, v]) => typeof v === 'number' ? Math.abs(r[k] - v) > 1e-9 : r[k] !== v);
    return { name: t.name, pass: !bad.length, detail: `C=${t.in[0]} E=${t.in[1]} O=${t.in[2]} N=${t.in[3]} → P=${r.raw}, S=${r.score.toFixed(4)} (${r.display}), ${r.passed ? 'superato' : 'non superato'}` + (bad.length ? ' · atteso ' + JSON.stringify(t.expect) : '') };
  } catch (e) { return { name: t.name, pass: !!t.expectThrow, detail: 'Errore: ' + e.message }; }
});

/* ---------- RNG ---------- */
function rng(seed) { return function () { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
const shuffle = (a, r) => { a = a.slice(); for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };
BL.rng = rng; BL.shuffle = shuffle;

/* ---------- TASSONOMIA DEMO ---------- */
const TAX = {
  areas: [{ id: 'a-loc', name: 'Enti locali' }, { id: 'a-cen', name: 'Amministrazioni centrali' }],
  entities: [
    { id: 'e-bv', area: 'a-loc', name: 'Comune di Borgoverde' },
    { id: 'e-uva', area: 'a-loc', name: 'Unione dei Comuni di Valle Alta' },
    { id: 'e-min', area: 'a-cen', name: 'Ministero dimostrativo' },
    { id: 'e-agn', area: 'a-cen', name: 'Agenzia nazionale dimostrativa' }],
  profiles: [
    { id: 'p-istr', name: 'Istruttore amministrativo', entities: ['e-bv', 'e-uva'], subjects: ['s-amm', 's-cost', 's-eell', 's-pi', 's-info'] },
    { id: 'p-cont', name: 'Istruttore contabile', entities: ['e-bv'], subjects: ['s-cont', 's-eell', 's-amm'] },
    { id: 'p-fun', name: 'Funzionario amministrativo', entities: ['e-min', 'e-agn'], subjects: ['s-amm', 's-cost', 's-pi', 's-info'] },
    { id: 'p-ass', name: 'Assistente amministrativo', entities: ['e-min'], subjects: ['s-cost', 's-pi', 's-info'] }],
  subjects: [
    { id: 's-amm', name: 'Diritto amministrativo' }, { id: 's-cost', name: 'Diritto costituzionale' },
    { id: 's-eell', name: 'Ordinamento degli enti locali' }, { id: 's-cont', name: 'Contabilità pubblica' },
    { id: 's-pi', name: 'Pubblico impiego' }, { id: 's-info', name: 'Informatica e PA digitale' }],
  topics: [
    { id: 't-proc', subject: 's-amm', name: 'Procedimento amministrativo' }, { id: 't-atti', subject: 's-amm', name: 'Atti e provvedimenti' },
    { id: 't-acc', subject: 's-amm', name: 'Accesso e trasparenza' }, { id: 't-princ', subject: 's-cost', name: 'Principi fondamentali' },
    { id: 't-org', subject: 's-cost', name: 'Organi costituzionali' }, { id: 't-organi', subject: 's-eell', name: 'Organi del comune' },
    { id: 't-funz', subject: 's-eell', name: 'Fonti e funzioni' }, { id: 't-bil', subject: 's-cont', name: 'Bilancio di previsione' },
    { id: 't-rend', subject: 's-cont', name: 'Rendiconto e principi' }, { id: 't-rapp', subject: 's-pi', name: 'Rapporto di lavoro' },
    { id: 't-comp', subject: 's-pi', name: 'Comportamento e anticorruzione' }, { id: 't-cad', subject: 's-info', name: 'Amministrazione digitale' },
    { id: 't-sic', subject: 's-info', name: 'Sicurezza e protezione dati' }]
};
const N = 'https://www.normattiva.it/uri-res/N2Ls?urn:nir:stato:';
const U = { l241: N + 'legge:1990-08-07;241', cost: N + 'costituzione', tuel: N + 'decreto.legislativo:2000-08-18;267', d165: N + 'decreto.legislativo:2001-03-30;165', dpr62: N + 'decreto.del.presidente.della.repubblica:2013-04-16;62', l190: N + 'legge:2012-11-06;190', d33: N + 'decreto.legislativo:2013-03-14;33', cad: N + 'decreto.legislativo:2005-03-07;82', gdpr: 'https://eur-lex.europa.eu/eli/reg/2016/679/oj', d118: N + 'decreto.legislativo:2011-06-23;118' };

const Q = (id, s, t, d, text, options, correct, explanation, source, sourceUrl) => ({ id, subject: s, topic: t, difficulty: d, text, options, correct, explanation, source, sourceUrl });
const QS = [
Q('q01','s-amm','t-proc',1,"Se la legge o un regolamento non prevedono un termine diverso, entro quanti giorni deve concludersi un procedimento amministrativo?",['30 giorni','60 giorni','90 giorni','120 giorni'],0,"L'art. 2 della L. 241/1990 fissa in 30 giorni il termine generale, salvo diversa previsione di legge o regolamento.",'L. 241/1990, art. 2',U.l241),
Q('q02','s-amm','t-proc',1,"Quale figura viene individuata per ogni procedimento ai sensi degli artt. 4-6 della L. 241/1990?",['Il difensore civico','Il responsabile del procedimento','Il segretario generale',"L'organo di indirizzo politico"],1,"Le amministrazioni individuano l'unità organizzativa e il responsabile del procedimento, che cura l'istruttoria.",'L. 241/1990, artt. 4-6',U.l241),
Q('q03','s-amm','t-proc',2,"Nei procedimenti a istanza di parte, prima di adottare un provvedimento negativo, l'amministrazione deve:",["Pubblicare l'atto all'albo pretorio",'Chiedere un parere al TAR',"Comunicare i motivi che ostano all'accoglimento della domanda",'Sospendere il procedimento per 90 giorni'],2,"È il preavviso di rigetto: l'interessato può presentare osservazioni entro 10 giorni.",'L. 241/1990, art. 10-bis',U.l241),
Q('q04','s-amm','t-proc',2,"Nei procedimenti a istanza di parte per cui opera il silenzio assenso, la mancata risposta nei termini equivale a:",['Rigetto della domanda','Accoglimento della domanda','Sospensione del procedimento',"Archiviazione d'ufficio"],1,"Salvo le eccezioni previste, il silenzio dell'amministrazione equivale a provvedimento di accoglimento.",'L. 241/1990, art. 20',U.l241),
Q('q05','s-amm','t-atti',1,"Un provvedimento adottato in violazione di legge è, di regola:",['Annullabile','Nullo','Inesistente','Pienamente valido'],0,"La violazione di legge, insieme a eccesso di potere e incompetenza, è causa di annullabilità.",'L. 241/1990, art. 21-octies',U.l241),
Q('q06','s-amm','t-atti',3,"Per i provvedimenti di autorizzazione o di attribuzione di vantaggi economici, l'annullamento d'ufficio può intervenire entro un termine non superiore a:",['18 mesi','3 anni','12 mesi','6 mesi'],2,"Il termine massimo è stato ridotto a dodici mesi dal D.L. 77/2021. Verificare sempre il testo vigente.",'L. 241/1990, art. 21-nonies',U.l241),
Q('q07','s-amm','t-atti',2,"La revoca di un provvedimento amministrativo può essere disposta:",['Solo per vizi di legittimità','Per sopravvenuti motivi di pubblico interesse','Esclusivamente dal giudice amministrativo','Solo su richiesta del destinatario'],1,"La revoca opera per sopravvenuti motivi di pubblico interesse, mutamento della situazione di fatto o nuova valutazione dell'interesse pubblico originario.",'L. 241/1990, art. 21-quinquies',U.l241),
Q('q08','s-amm','t-acc',1,"L'accesso civico generalizzato è disciplinato da:",['L. 190/2012','D.Lgs. 165/2001','D.Lgs. 33/2013','D.P.R. 445/2000'],2,"Il D.Lgs. 33/2013, modificato dal D.Lgs. 97/2016, consente a chiunque di accedere a dati e documenti ulteriori rispetto a quelli pubblicati.",'D.Lgs. 33/2013, art. 5',U.d33),
Q('q09','s-amm','t-acc',2,"Il diritto di accesso ai documenti amministrativi ai sensi della L. 241/1990 spetta a chi ha:",['Un interesse diretto, concreto e attuale','Qualsiasi curiosità, senza motivazione','La qualifica di dipendente pubblico',"L'iscrizione a un albo professionale"],0,"L'accesso documentale richiede un interesse diretto, concreto e attuale, collegato al documento richiesto.",'L. 241/1990, art. 22',U.l241),
Q('q10','s-amm','t-acc',2,"Decorsi inutilmente 30 giorni dalla richiesta di accesso ai documenti, la richiesta si intende:",['Accolta','Respinta','Sospesa','Trasferita al prefetto'],1,"L'art. 25 prevede il silenzio rigetto: il richiedente può ricorrere al TAR o al difensore civico.",'L. 241/1990, art. 25',U.l241),
Q('q11','s-cost','t-princ',1,"Secondo l'art. 97 della Costituzione, i pubblici uffici sono organizzati in modo da assicurare:",['La massima redditività',"Il buon andamento e l'imparzialità",'La riservatezza degli atti',"L'autonomia finanziaria"],1,"L'art. 97 richiama il buon andamento e l'imparzialità dell'amministrazione.",'Costituzione, art. 97',U.cost),
Q('q12','s-cost','t-princ',1,"Agli impieghi nelle pubbliche amministrazioni si accede, salvo i casi stabiliti dalla legge, mediante:",['Chiamata diretta','Concorso','Sorteggio pubblico',"Nomina dell'organo politico"],1,"L'art. 97, ultimo comma, stabilisce la regola del concorso.",'Costituzione, art. 97',U.cost),
Q('q13','s-cost','t-princ',1,"Quale articolo della Costituzione afferma il principio di uguaglianza?",['Art. 1','Art. 3','Art. 5','Art. 12'],1,"L'art. 3 sancisce l'uguaglianza formale (primo comma) e sostanziale (secondo comma).",'Costituzione, art. 3',U.cost),
Q('q14','s-cost','t-org',1,"Il Presidente della Repubblica è eletto da:",['I cittadini con voto diretto','Il Senato','Il Parlamento in seduta comune, integrato dai delegati regionali','La Corte costituzionale'],2,"L'art. 83 prevede l'elezione da parte del Parlamento in seduta comune con tre delegati per Regione (uno per la Valle d'Aosta).",'Costituzione, art. 83',U.cost),
Q('q15','s-cost','t-org',2,"Dopo la riforma costituzionale del 2020, quanti sono i deputati?",['630','315','400','200'],2,"La L. cost. 1/2020 ha ridotto i deputati a 400 e i senatori elettivi a 200.",'Costituzione, art. 56',U.cost),
Q('q16','s-cost','t-org',1,"Quanto dura il mandato del Presidente della Repubblica?",['5 anni','7 anni','6 anni','9 anni'],1,"L'art. 85 fissa la durata in sette anni.",'Costituzione, art. 85',U.cost),
Q('q17','s-cost','t-org',2,"Qual è l'età minima per essere eletti Presidente della Repubblica?",['40 anni','35 anni','50 anni','45 anni'],2,"L'art. 84 richiede il compimento di cinquant'anni di età.",'Costituzione, art. 84',U.cost),
Q('q18','s-eell','t-organi',1,"Secondo il TUEL, gli organi di governo del comune sono:",['Consiglio, giunta e sindaco','Consiglio, segretario e sindaco','Giunta, revisore e sindaco','Consiglio, prefetto e giunta'],0,"L'art. 36 del TUEL individua consiglio, giunta e sindaco come organi di governo.",'D.Lgs. 267/2000, art. 36',U.tuel),
Q('q19','s-eell','t-organi',1,"Qual è la durata ordinaria del mandato del sindaco?",['4 anni','5 anni','6 anni','3 anni'],1,"Il sindaco e il consiglio comunale durano in carica cinque anni.",'D.Lgs. 267/2000, art. 51',U.tuel),
Q('q20','s-eell','t-funz',1,"Il Testo unico delle leggi sull'ordinamento degli enti locali è stato approvato con:",['L. 142/1990','D.Lgs. 165/2001','D.Lgs. 267/2000','L. 241/1990'],2,"Il TUEL è il D.Lgs. 18 agosto 2000, n. 267.",'D.Lgs. 267/2000',U.tuel),
Q('q21','s-eell','t-organi',2,"Chi nomina i componenti della giunta comunale?",['Il consiglio comunale','Il sindaco','Il prefetto','Il segretario comunale'],1,"Il sindaco nomina i componenti della giunta e ne dà comunicazione al consiglio nella prima seduta.",'D.Lgs. 267/2000, art. 46',U.tuel),
Q('q22','s-eell','t-funz',2,"Lo statuto comunale è deliberato da:",['La giunta','Il sindaco','Il consiglio comunale','La conferenza dei capigruppo'],2,"Lo statuto è deliberato dal consiglio con le maggioranze previste dall'art. 6.",'D.Lgs. 267/2000, art. 6',U.tuel),
Q('q23','s-cont','t-bil',2,"Entro quale data il TUEL prevede la deliberazione del bilancio di previsione finanziario?",['31 dicembre','30 aprile','31 luglio','30 giugno'],0,"L'art. 151 indica il 31 dicembre dell'anno precedente; il termine può essere differito con decreto.",'D.Lgs. 267/2000, art. 151',U.tuel),
Q('q24','s-cont','t-bil',2,"Il piano esecutivo di gestione (PEG) è deliberato da:",['Il consiglio comunale','La giunta',"L'organo di revisione",'Il responsabile finanziario'],1,"Il PEG è deliberato dalla giunta in coerenza con il bilancio di previsione e il DUP.",'D.Lgs. 267/2000, art. 169',U.tuel),
Q('q25','s-cont','t-rend',2,"Il rendiconto della gestione è deliberato dal consiglio entro il:",['31 dicembre',"30 aprile dell'anno successivo",'31 luglio','30 settembre'],1,"L'art. 227 fissa il termine del 30 aprile dell'anno successivo.",'D.Lgs. 267/2000, art. 227',U.tuel),
Q('q26','s-cont','t-rend',3,"Il principio che impone di registrare le obbligazioni perfezionate con imputazione all'esercizio in cui scadono è:",['La cassa pura','La competenza economica','La competenza finanziaria potenziata',"Il principio di annualità"],2,"È il principio cardine dell'armonizzazione contabile introdotta dal D.Lgs. 118/2011.",'D.Lgs. 118/2011, all. 4/2',U.d118),
Q('q27','s-pi','t-rapp',1,"Le norme generali sull'ordinamento del lavoro alle dipendenze delle PA sono contenute nel:",['D.Lgs. 165/2001','D.Lgs. 267/2000','D.P.R. 3/1957','L. 300/1970'],0,"Il D.Lgs. 165/2001 è il testo di riferimento per il pubblico impiego contrattualizzato.",'D.Lgs. 165/2001',U.d165),
Q('q28','s-pi','t-rapp',2,"Secondo il D.Lgs. 165/2001, ai dirigenti spetta:",['La definizione degli obiettivi politici','La gestione finanziaria, tecnica e amministrativa',"L'approvazione del bilancio",'La nomina degli organi di governo'],1,"L'art. 4 distingue l'indirizzo politico, proprio degli organi di governo, dalla gestione, affidata ai dirigenti.",'D.Lgs. 165/2001, art. 4',U.d165),
Q('q29','s-pi','t-comp',1,"Il codice di comportamento dei dipendenti pubblici è stato adottato con:",['D.P.R. 445/2000','D.P.R. 62/2013','L. 190/2012','D.Lgs. 33/2013'],1,"Il D.P.R. 62/2013, aggiornato dal D.P.R. 81/2023, definisce i doveri minimi di diligenza, lealtà e imparzialità.",'D.P.R. 62/2013',U.dpr62),
Q('q30','s-pi','t-comp',1,"La L. 190/2012 riguarda principalmente:",['La riforma della dirigenza',"La prevenzione della corruzione e dell'illegalità",'Il bilancio degli enti locali','La firma digitale'],1,"La legge ha introdotto il sistema di prevenzione della corruzione nelle pubbliche amministrazioni.",'L. 190/2012',U.l190),
Q('q31','s-info','t-cad',1,"Il Codice dell'amministrazione digitale (CAD) è contenuto nel:",['D.Lgs. 82/2005','D.Lgs. 196/2003','D.P.R. 445/2000','L. 4/2004'],0,"Il CAD è il D.Lgs. 7 marzo 2005, n. 82.",'D.Lgs. 82/2005',U.cad),
Q('q32','s-info','t-cad',1,"Rispetto a una e-mail ordinaria, la posta elettronica certificata (PEC):",['È sempre crittografata end-to-end','Ha valore legale per invio e consegna','Non può contenere allegati','È utilizzabile solo tra pubbliche amministrazioni'],1,"La PEC fornisce ricevute di accettazione e consegna opponibili ai terzi.",'D.Lgs. 82/2005, art. 48',U.cad),
Q('q33','s-info','t-sic',1,"Il Regolamento generale sulla protezione dei dati (GDPR) è il:",['Reg. UE 2016/679','Direttiva 95/46/CE','D.Lgs. 196/2003','Reg. UE 910/2014'],0,"Il GDPR è applicabile dal 25 maggio 2018.",'Reg. (UE) 2016/679',U.gdpr),
Q('q34','s-info','t-sic',1,"Quale misura riduce maggiormente il rischio di accessi non autorizzati a un account?",['Una password breve ma facile da ricordare',"L'autenticazione a più fattori",'Condividere la password con un collega fidato','Disattivare gli aggiornamenti'],1,"L'autenticazione a più fattori richiede un elemento aggiuntivo oltre alla password.",'Buone pratiche di sicurezza (fonte da specificare)',''),
Q('q35','s-cont','t-bil',2,"Il Documento unico di programmazione (DUP) si compone di:",['Parte entrate e parte spese','Sezione strategica e sezione operativa','Titoli e missioni','Conto economico e stato patrimoniale'],1,"Il DUP ha una sezione strategica, con orizzonte pari al mandato, e una sezione operativa, con orizzonte pari al bilancio.",'D.Lgs. 267/2000, art. 170',U.tuel),
Q('q36','s-cont','t-bil',2,"Chi esprime il parere sulla proposta di bilancio di previsione del comune?",['La giunta','Il segretario comunale',"L'organo di revisione economico-finanziaria",'La Corte dei conti'],2,"L'organo di revisione esprime pareri sulla proposta di bilancio e sui documenti allegati.",'D.Lgs. 267/2000, art. 239',U.tuel),
Q('q37','s-cont','t-bil',1,"Il bilancio di previsione finanziario degli enti locali riguarda un periodo di almeno:",['Tre anni','Un anno','Cinque anni','Due anni'],0,"Il bilancio di previsione finanziario è almeno triennale.",'D.Lgs. 267/2000, art. 162',U.tuel),
Q('q38','s-pi','t-rapp',2,"Il Piano integrato di attività e organizzazione (PIAO) è stato introdotto dal:",['D.Lgs. 150/2009','L. 190/2012','D.Lgs. 33/2013','D.L. 80/2021'],3,"L'art. 6 del D.L. 80/2021 ha introdotto il PIAO, che integra diversi piani delle amministrazioni.",'D.L. 80/2021, art. 6',N+'decreto.legge:2021-06-09;80'),
Q('q39','s-pi','t-comp',1,"Il Responsabile della prevenzione della corruzione e della trasparenza (RPCT) è previsto dalla:",['L. 241/1990','L. 190/2012','D.Lgs. 82/2005','D.P.R. 445/2000'],1,"La L. 190/2012 prevede che ogni amministrazione individui il RPCT.",'L. 190/2012, art. 1, c. 7',U.l190),
Q('q40','s-pi','t-comp',2,"Secondo il codice di comportamento, il dipendente pubblico può accettare regali:",['Di qualsiasi valore, purché non in denaro','Mai, in nessun caso','Solo di modico valore, nell\'ambito delle normali relazioni di cortesia','Solo da altri dipendenti'],2,"L'art. 4 del D.P.R. 62/2013 ammette solo regali d'uso di modico valore, nei limiti indicati dal codice.",'D.P.R. 62/2013, art. 4',U.dpr62),
Q('q41','s-info','t-cad',1,"Nell'amministrazione digitale, SPID è:",["Il sistema pubblico di identità digitale",'Un servizio di posta certificata','Un formato di firma elettronica','Un archivio documentale'],0,"SPID consente l'accesso ai servizi online delle pubbliche amministrazioni con un'unica identità digitale.",'D.Lgs. 82/2005, art. 64',U.cad),
Q('q42','s-info','t-cad',2,"La firma digitale si basa su:",['Una password condivisa','Un codice ricevuto via SMS','La scansione della firma autografa','Un sistema di chiavi crittografiche asimmetriche'],3,"La firma digitale usa una coppia di chiavi, una privata e una pubblica, collegate a un certificato qualificato.",'D.Lgs. 82/2005, art. 1',U.cad),
Q('q43','s-info','t-sic',2,"Secondo il GDPR, una violazione dei dati personali va notificata all'autorità di controllo, ove possibile, entro:",['24 ore','72 ore','7 giorni','30 giorni'],1,"L'art. 33 del GDPR prevede la notifica senza ingiustificato ritardo e, ove possibile, entro 72 ore.",'Reg. (UE) 2016/679, art. 33',U.gdpr),
Q('q44','s-eell','t-funz',2,"Lo statuto e i regolamenti comunali rientrano, di regola, nella competenza:",['Della giunta','Del sindaco','Del consiglio comunale','Del segretario comunale'],2,"L'art. 42 del TUEL attribuisce al consiglio gli atti fondamentali, tra cui statuto e regolamenti, salvo il regolamento sull'ordinamento degli uffici e dei servizi.",'D.Lgs. 267/2000, art. 42',U.tuel),
Q('q45','s-eell','t-organi',1,"Chi presiede la giunta comunale?",['Il sindaco','Il presidente del consiglio','Il segretario comunale','Il vicesindaco'],0,"Il sindaco convoca e presiede la giunta.",'D.Lgs. 267/2000, art. 50',U.tuel),
Q('q46','s-amm','t-atti',2,"L'obbligo di motivazione previsto dall'art. 3 della L. 241/1990 non si applica:",['Ai provvedimenti sanzionatori','Ai dinieghi','Alle autorizzazioni','Agli atti normativi e a quelli a contenuto generale'],3,"L'art. 3, comma 2, esclude dall'obbligo di motivazione gli atti normativi e quelli a contenuto generale.",'L. 241/1990, art. 3',U.l241),
Q('q47','s-amm','t-proc',2,"La conferenza di servizi è disciplinata dagli artt. 14 e seguenti della:",['L. 190/2012','L. 241/1990','D.Lgs. 165/2001','D.Lgs. 267/2000'],1,"La conferenza di servizi è uno strumento di semplificazione per l'esame contestuale degli interessi pubblici coinvolti.",'L. 241/1990, artt. 14 e ss.',U.l241),
Q('q48','s-cost','t-org',2,"Il Governo della Repubblica è composto da:",['I soli ministri con portafoglio','Il Presidente della Repubblica e i ministri','Il Presidente del Consiglio e i ministri, che costituiscono il Consiglio dei ministri','Il Parlamento e i ministri'],2,"L'art. 92 della Costituzione definisce la composizione del Governo.",'Costituzione, art. 92',U.cost),
Q('q49','s-cost','t-princ',1,"Secondo l'art. 1 della Costituzione, la sovranità appartiene:",['Al popolo','Al Parlamento','Al Presidente della Repubblica','Al Governo'],0,"La sovranità appartiene al popolo, che la esercita nelle forme e nei limiti della Costituzione.",'Costituzione, art. 1',U.cost),
Q('q93','s-amm','t-proc',1,"Qual è il termine ordinario di conclusione del procedimento amministrativo in assenza di diversa previsione?",['30 giorni','45 giorni','60 giorni','180 giorni'],0,"Termine generale previsto dall'art. 2 della L. 241/1990.",'L. 241/1990, art. 2',U.l241)
];
BL.DEMO_QUIZ_IDS = ['q01', 'q11', 'q19', 'q31', 'q33'];

function derive(tax, subject) {
  const profiles = tax.profiles.filter(p => p.subjects.includes(subject)).map(p => p.id);
  const entities = [...new Set(tax.profiles.filter(p => profiles.includes(p.id)).flatMap(p => p.entities))];
  return { profiles, entities };
}
function buildQuestions() {
  const t0 = Date.now() - 120 * DAY;
  return QS.map((q, i) => {
    const late = q.id === 'q06' || q.id === 'q15', soon = q.id === 'q26';
    const lastVerified = late ? addDays(todayISO(), -380) : addDays(todayISO(), -40 - i);
    const nextReview = late ? addDays(todayISO(), -15) : soon ? addDays(todayISO(), 18) : addDays(lastVerified, 365);
    const v = Object.assign({ v: 1, status: 'published', lastVerified, nextReview, author: i % 2 ? 'u-ed2' : 'u-ed', reviewer: 'u-rev', createdAt: t0 + i * 3600e3, publishedAt: t0 + 2 * DAY + i * 3600e3, note: 'Prima versione' }, q, derive(TAX, q.subject));
    delete v.id;
    return { id: q.id, demo: true, suspended: false, mergedInto: null, current: 1, versions: [v] };
  }).concat(extraQuestions());
}
function blankVersion(author) {
  return { v: 1, status: 'draft', text: '', options: ['', '', '', ''], correct: null, explanation: '', subject: '', topic: '', difficulty: null, source: '', sourceUrl: '', lastVerified: '', nextReview: '', profiles: [], entities: [], author, reviewer: null, createdAt: Date.now(), note: 'Nuova domanda' };
}
function extraQuestions() {
  const now = Date.now();
  const mk = (id, status, author, data, extra) => ({ id, demo: true, suspended: false, mergedInto: null, current: null, versions: [Object.assign(blankVersion(author), data, derive(TAX, data.subject || ''), { status, createdAt: now - 3 * DAY }, extra || {})] });
  const q12 = (() => { const base = QS.find(q => q.id === 'q12'); return base; })();
  const out = [
    mk('q90', 'draft', 'u-ed', { text: "Che cosa si intende per «conferenza di servizi»?", options: ["Uno strumento di semplificazione per l'esame contestuale degli interessi pubblici", 'Un organo collegiale permanente del comune', '', ''], correct: 0, explanation: '', subject: 's-amm', topic: 't-proc', difficulty: 2 }),
    mk('q91', 'review', 'u-ed2', { text: "Entro quale data la giunta presenta al consiglio il Documento unico di programmazione (DUP)?", options: ['31 luglio', '31 dicembre', '30 aprile', '15 novembre'], correct: 0, explanation: "L'art. 170 del TUEL prevede la presentazione del DUP entro il 31 luglio.", subject: 's-cont', topic: 't-bil', difficulty: 2, source: 'D.Lgs. 267/2000, art. 170', sourceUrl: U.tuel, lastVerified: addDays(todayISO(), -5), nextReview: addDays(todayISO(), 360) }),
    mk('q92', 'changes', 'u-ed', { text: "Quanti sono i senatori elettivi dopo la riforma del 2020?", options: ['200', '315', '400', '100'], correct: 0, explanation: 'La L. cost. 1/2020 ha ridotto i senatori elettivi a 200.', subject: 's-cost', topic: 't-org', difficulty: 2, source: 'Costituzione, art. 57', sourceUrl: U.cost, lastVerified: addDays(todayISO(), -8), nextReview: addDays(todayISO(), 357) }, { reviewer: 'u-rev', reviewNote: 'Distinguere nella spiegazione i senatori elettivi da quelli a vita.' })
  ];
  out.q12v2 = q12;
  return out;
}
function addQ12v2(questions) {
  const q = questions.find(x => x.id === 'q12');
  const v2 = Object.assign(clone(q.versions[0]), { v: 2, status: 'review', explanation: "L'art. 97, quarto comma, stabilisce che agli impieghi nelle PA si accede mediante concorso, salvo i casi stabiliti dalla legge.", author: 'u-ed2', reviewer: null, createdAt: Date.now() - 2 * DAY, publishedAt: null, note: "Allineata la spiegazione al testo dell'art. 97, quarto comma" });
  q.versions.push(v2);
}

/* ---------- MATERIALI ---------- */
const sec = (title, body) => ({ title, body });
const MATS = [
  { id: 'm01', title: 'La legge 241/1990 in sintesi', subject: 's-amm', topic: 't-proc', format: 'scheda', minutes: 12, source: 'L. 241/1990', keyConcepts: ['Termine generale: 30 giorni', 'Responsabile del procedimento', 'Preavviso di rigetto (art. 10-bis)', 'Silenzio assenso (art. 20)'], related: ['m02'], sections: [
    sec('Principi generali', "L'attività amministrativa persegue i fini determinati dalla legge ed è retta da criteri di economicità, efficacia, imparzialità, pubblicità e trasparenza (art. 1). L'amministrazione non può aggravare il procedimento se non per straordinarie e motivate esigenze."),
    sec('Termini del procedimento', "Il procedimento si conclude con un provvedimento espresso. In assenza di un termine diverso la durata è di 30 giorni (art. 2). Termini più lunghi, fino a 90 o, in casi particolari, 180 giorni, possono essere stabiliti nei casi previsti."),
    sec('Responsabile del procedimento', "Per ogni procedimento è individuato un responsabile (artt. 4-6), che valuta i presupposti, cura l'istruttoria, può chiedere la rettifica di dichiarazioni e propone o adotta il provvedimento finale."),
    sec('Partecipazione', "L'avvio del procedimento è comunicato ai soggetti interessati (art. 7). Nei procedimenti a istanza di parte, prima di un diniego, l'amministrazione comunica i motivi ostativi (art. 10-bis) e l'interessato può presentare osservazioni entro 10 giorni."),
    sec('Silenzio della PA', "Nei casi previsti dall'art. 20 il silenzio equivale ad accoglimento. Negli altri casi l'inerzia può essere contestata davanti al giudice amministrativo.")] },
  { id: 'm02', title: 'Accesso documentale e accesso civico', subject: 's-amm', topic: 't-acc', format: 'scheda', minutes: 9, source: 'L. 241/1990; D.Lgs. 33/2013', keyConcepts: ['Interesse diretto, concreto e attuale', 'Accesso civico semplice', 'Accesso civico generalizzato', 'Silenzio rigetto dopo 30 giorni'], related: ['m01'], sections: [
    sec('Accesso documentale', "Disciplinato dagli artt. 22 e seguenti della L. 241/1990, spetta a chi ha un interesse diretto, concreto e attuale corrispondente a una situazione giuridicamente tutelata."),
    sec('Accesso civico semplice', "Previsto dal D.Lgs. 33/2013, consente a chiunque di richiedere documenti e dati che l'amministrazione aveva l'obbligo di pubblicare e non ha pubblicato."),
    sec('Accesso civico generalizzato', "Consente a chiunque, senza motivazione, di accedere a dati e documenti ulteriori rispetto a quelli soggetti a pubblicazione, nel rispetto dei limiti a tutela di interessi pubblici e privati."),
    sec('Limiti e silenzio', "Decorsi 30 giorni dalla richiesta di accesso documentale senza risposta, la richiesta si intende respinta (art. 25).")] },
  { id: 'm03', title: 'Gli organi del comune', subject: 's-eell', topic: 't-organi', format: 'scheda', minutes: 10, source: 'D.Lgs. 267/2000', keyConcepts: ['Consiglio, giunta e sindaco', 'Mandato di cinque anni', 'La giunta è nominata dal sindaco'], related: ['m06'], sections: [
    sec('Consiglio comunale', "È l'organo di indirizzo e di controllo politico-amministrativo. Delibera lo statuto, i regolamenti, i bilanci e gli atti fondamentali indicati dall'art. 42 del TUEL."),
    sec('Giunta', "Collabora con il sindaco nel governo del comune e compie gli atti che non sono riservati dalla legge al consiglio. I componenti sono nominati dal sindaco (art. 46)."),
    sec('Sindaco', "È l'organo responsabile dell'amministrazione del comune, rappresenta l'ente e sovrintende al funzionamento dei servizi e degli uffici. Dura in carica cinque anni."),
    sec('Segretario comunale', "Svolge compiti di collaborazione e funzioni di assistenza giuridico-amministrativa nei confronti degli organi dell'ente.")] },
  { id: 'm04', title: 'Principi fondamentali della Costituzione', subject: 's-cost', topic: 't-princ', format: 'scheda', minutes: 8, source: 'Costituzione, artt. 1-12 e 97', keyConcepts: ['Uguaglianza formale e sostanziale', 'Buon andamento e imparzialità', 'Accesso agli impieghi mediante concorso'], related: ['m01'], sections: [
    sec('Gli articoli 1-12', "I primi dodici articoli definiscono i caratteri della Repubblica: democratica e fondata sul lavoro, garante dei diritti inviolabili, una e indivisibile, aperta all'ordinamento internazionale."),
    sec('Uguaglianza', "L'art. 3 afferma l'uguaglianza davanti alla legge (formale) e impegna la Repubblica a rimuovere gli ostacoli economici e sociali che la limitano (sostanziale)."),
    sec("L'amministrazione nella Costituzione", "L'art. 97 richiede che i pubblici uffici siano organizzati secondo il buon andamento e l'imparzialità e che agli impieghi si acceda mediante concorso, salvo i casi stabiliti dalla legge.")] },
  { id: 'm05', title: 'Il ciclo del bilancio negli enti locali', subject: 's-cont', topic: 't-bil', format: 'scheda', minutes: 11, source: 'D.Lgs. 267/2000; D.Lgs. 118/2011', keyConcepts: ['DUP entro il 31 luglio', 'Bilancio entro il 31 dicembre', 'PEG deliberato dalla giunta', 'Rendiconto entro il 30 aprile'], related: ['m06'], sections: [
    sec('Programmazione: il DUP', "Il Documento unico di programmazione guida strategicamente e operativamente l'ente ed è presentato dalla giunta al consiglio entro il 31 luglio."),
    sec('Bilancio di previsione', "Il bilancio di previsione finanziario è deliberato entro il 31 dicembre e riguarda almeno un triennio."),
    sec('PEG', "Il piano esecutivo di gestione, deliberato dalla giunta, affida obiettivi e risorse ai responsabili dei servizi."),
    sec('Rendiconto', "Il rendiconto della gestione è deliberato dal consiglio entro il 30 aprile dell'anno successivo.")] },
  { id: 'm06', title: 'Schema riassuntivo TUEL', subject: 's-eell', topic: 't-funz', format: 'pdf-download', minutes: 5, source: 'D.Lgs. 267/2000', keyConcepts: [], related: ['m03'], sections: [] },
  { id: 'm07', title: 'Codice di comportamento: guida alla lettura', subject: 's-pi', topic: 't-comp', format: 'pdf-view', minutes: 15, source: 'D.P.R. 62/2013', keyConcepts: [], related: [], sections: [] },
  { id: 'm08', title: 'La conferenza di servizi', subject: 's-amm', topic: 't-proc', format: 'scheda', minutes: 7, source: 'L. 241/1990, artt. 14 e ss.', keyConcepts: [], related: [], sections: [sec('Bozza', 'Contenuto in preparazione.')], status: 'draft', author: 'u-ed' }
];
function buildMaterials() {
  return MATS.map((m, i) => Object.assign({ status: 'published', demo: true, author: 'u-ed', lastVerified: addDays(todayISO(), -30 - i), nextReview: addDays(todayISO(), 330 - i) }, clone(m), derive(TAX, m.subject), { sections: m.sections.map((s, j) => Object.assign({ id: m.id + '-s' + (j + 1) }, s)) }));
}
const QUIZZES = [
  { id: 'z01', title: 'Procedimento amministrativo: le basi', mode: 'training', filter: { topics: ['t-proc'] }, count: 4, status: 'published' },
  { id: 'z02', title: 'Costituzione: principi e organi', mode: 'training', filter: { subjects: ['s-cost'] }, count: 7, status: 'published' },
  { id: 'z03', title: 'Simulazione breve — Istruttore amministrativo', mode: 'exam', filter: { subjects: ['s-amm', 's-cost', 's-eell', 's-pi', 's-info'] }, count: 15, durationMin: 20, status: 'published' },
  { id: 'z04', title: 'Contabilità: bilancio e rendiconto', mode: 'training', filter: { subjects: ['s-cont'] }, count: 4, status: 'draft' },
  { id: 'z05', title: 'Simulazione completa — Funzionario amministrativo', mode: 'exam', filter: { subjects: ['s-amm', 's-cost', 's-pi', 's-info'] }, count: 40, durationMin: 45, status: 'draft' }
];
const PATHS = [
  { id: 'pt01', title: 'Fondamenti per Istruttore amministrativo', profile: 'p-istr', desc: 'Principi costituzionali, procedimento e organi del comune, con una simulazione finale.', steps: [
    { id: 'st1', type: 'material', ref: 'm04', title: 'Principi fondamentali della Costituzione' },
    { id: 'st2', type: 'quiz', filter: { topics: ['t-princ'] }, count: 3, title: 'Quiz: principi fondamentali' },
    { id: 'st3', type: 'material', ref: 'm01', title: 'La legge 241/1990 in sintesi' },
    { id: 'st4', type: 'quiz', filter: { topics: ['t-proc'] }, count: 4, title: 'Quiz: procedimento amministrativo' },
    { id: 'st5', type: 'material', ref: 'm03', title: 'Gli organi del comune' },
    { id: 'st6', type: 'quiz', filter: { topics: ['t-organi'] }, count: 3, title: 'Quiz: organi del comune' },
    { id: 'st7', type: 'exam', quiz: 'z03', title: 'Simulazione breve' }] },
  { id: 'pt02', title: 'Contabilità degli enti locali', profile: 'p-cont', desc: 'Il ciclo del bilancio, dal DUP al rendiconto.', steps: [
    { id: 'st1', type: 'material', ref: 'm05', title: 'Il ciclo del bilancio negli enti locali' },
    { id: 'st2', type: 'quiz', filter: { subjects: ['s-cont'] }, count: 4, title: 'Quiz: contabilità pubblica' },
    { id: 'st3', type: 'material', ref: 'm06', title: 'Schema riassuntivo TUEL (PDF)' },
    { id: 'st4', type: 'quiz', filter: { topics: ['t-rend'] }, count: 2, title: 'Quiz: rendiconto' }] }
];
const USERS = [
  { id: 'u-new', name: 'Giulia Neri', email: 'giulia.neri@example.com', role: 'user', persona: 'Nuovo utente', desc: 'Primo accesso, nessuna attività.' },
  { id: 'u-reg', name: 'Marco Esposito', email: 'marco.esposito@example.com', role: 'user', persona: 'Utente abituale', desc: 'Tre settimane di attività dimostrativa.' },
  { id: 'u-ed', name: 'Sara Conti', email: 'sara.conti@example.com', role: 'editor', persona: 'Editor', desc: 'Crea e modifica contenuti.' },
  { id: 'u-ed2', name: 'Luca Ferri', email: 'luca.ferri@example.com', role: 'editor', persona: 'Editor', desc: 'Crea e modifica contenuti.' },
  { id: 'u-rev', name: 'Paolo Ricci', email: 'paolo.ricci@example.com', role: 'reviewer', persona: 'Revisore', desc: 'Approva, verifica, gestisce segnalazioni.' },
  { id: 'u-adm', name: 'Elena Marino', email: 'elena.marino@example.com', role: 'admin', persona: 'Amministratore', desc: 'Utenti, ruoli, catalogo e impostazioni.' }
];
BL.ROLES = { user: 'Utente', editor: 'Editor', reviewer: 'Revisore', admin: 'Amministratore' };
BL.STATUS = { draft: 'Bozza', review: 'In revisione', changes: 'Modifiche richieste', approved: 'Approvato', published: 'Pubblicato', rejected: 'Rifiutato', superseded: 'Sostituita' };
BL.DIFF = { 1: 'Base', 2: 'Intermedia', 3: 'Avanzata' };
BL.FORMAT = { scheda: 'Scheda online', 'pdf-view': 'PDF consultabile', 'pdf-download': 'PDF scaricabile' };

/* ---------- STATO ---------- */
function newRec() {
  return { onboarded: false, prefs: { area: null, profiles: [], perDay: null, examDate: '', quizCount: 10, difficulty: 'mix', explain: 'after', notif: { goals: true, progress: true, content: true }, reduceMotion: false }, attempts: [], session: null, read: {}, bookmarks: {}, completed: {}, paths: {}, notifications: [], xpLog: [], reviewed: {}, requests: [] };
}
function seedRegular(bank) {
  const rec = newRec(); const r = rng(11); const now = Date.now();
  Object.assign(rec.prefs, { area: 'a-loc', profiles: ['p-istr'], perDay: 20 }); rec.onboarded = true;
  const pool = bank.questions.filter(BL.isLive);
  const acc = { 's-amm': .68, 's-cost': .8, 's-eell': .5, 's-cont': .45, 's-pi': .7, 's-info': .85 };
  const plan = [[-20, 'training', 8, 'z01'], [-19, 'training', 10, 'cfg'], [-17, 'exam', 15, 'z03'], [-15, 'training', 10, 'cfg'], [-14, 'training', 7, 'z02'], [-12, 'exam', 15, 'z03'], [-10, 'training', 10, 'cfg'], [-8, 'training', 6, 'cfg'], [-7, 'exam', 15, 'z03'], [-5, 'training', 10, 'cfg'], [-3, 'training', 10, 'cfg'], [-2, 'exam', 15, 'z03'], [-1, 'training', 8, 'cfg']];
  plan.forEach(([d, mode, n, key], i) => {
    const qs = shuffle(pool, r).slice(0, n);
    const items = qs.map(q => { const v = BL.live(q); let answer; if (r() < .07) answer = null; else if (r() < Math.min(.95, acc[v.subject] + i * .012)) answer = v.correct; else answer = (v.correct + 1 + Math.floor(r() * 3)) % 4; return { qid: q.id, v: v.v, answer, correct: answer === v.correct }; });
    const start = now + d * DAY - 3 * 3600e3 + Math.floor(r() * 3600e3); const dur = n * (35 + Math.floor(r() * 30));
    const score = BL.scoreItems(items);
    const title = key === 'z03' ? 'Simulazione breve — Istruttore amministrativo' : key === 'z01' ? 'Procedimento amministrativo: le basi' : key === 'z02' ? 'Costituzione: principi e organi' : 'Allenamento personalizzato';
    rec.attempts.push({ id: 'a' + (i + 1), mode, title, key: key === 'cfg' ? 'cfg-' + i : key, startedAt: start, finishedAt: start + dur * 1000, durationSec: dur, items, score, reason: 'submitted', interruptions: [], status: 'completed', demo: true });
    rec.xpLog.push({ at: start + dur * 1000, amount: 10 + score.C, reason: 'Quiz completato' });
  });
  rec.xpLog.push({ at: now - 7 * DAY, amount: 15, reason: 'Miglioramento in simulazione comparabile' });
  rec.xpLog.push({ at: now - 5 * DAY, amount: 5, reason: 'Revisione degli errori' });
  rec.reviewed = { a9: true, a10: true };
  rec.read = { m04: { sections: ['m04-s1', 'm04-s2', 'm04-s3'], last: 'm04-s3', at: now - 18 * DAY }, m01: { sections: ['m01-s1', 'm01-s2'], last: 'm01-s2', at: now - 2 * DAY } };
  rec.completed = { m04: now - 18 * DAY }; rec.xpLog.push({ at: now - 18 * DAY, amount: 8, reason: 'Materiale completato' });
  rec.bookmarks = { m01: ['m01-s2'] };
  rec.paths = { pt01: { order: PATHS[0].steps.map(s => s.id), status: { st1: 'done', st2: 'done' }, at: now - 17 * DAY } };
  rec.notifications = [
    { id: 'n1', type: 'goal', title: 'Obiettivo di oggi', body: 'Il tuo obiettivo è di 20 risposte. Puoi iniziare con un quiz breve.', at: now - 2 * 3600e3, read: false },
    { id: 'n2', type: 'content', title: 'Materiale aggiornato', body: 'La scheda «La legge 241/1990 in sintesi» è stata aggiornata dal team editoriale.', at: now - 1 * DAY, read: false },
    { id: 'n3', type: 'progress', title: 'Nuovo badge', body: 'Hai ottenuto il badge «Tre giorni di fila».', at: now - 1 * DAY - 3600e3, read: true },
    { id: 'n4', type: 'content', title: 'Segnalazione ricevuta', body: 'La tua segnalazione sulla domanda «deputati dopo la riforma» è in coda di revisione.', at: now - 4 * DAY, read: true }];
  return rec;
}
function seed() {
  const demo = { taxonomy: clone(TAX), questions: buildQuestions(), materials: buildMaterials(), quizzes: clone(QUIZZES), paths: clone(PATHS) };
  addQ12v2(demo.questions);
  const real = { taxonomy: { areas: clone(TAX.areas), entities: [], profiles: [], subjects: [], topics: [] }, questions: [], materials: [], quizzes: [], paths: [] };
  const now = Date.now();
  const S = { schema: 1, createdAt: now, theme: 'light', auth: null, users: clone(USERS), data: { demo, real }, recs: {}, settings: { requireUrl: true, requireExplanation: true, verifyMonths: 12, demoEnabled: true },
    reports: [
      { id: 'r1', qid: 'q15', v: 1, by: 'u-reg', reason: 'Possibile errore', text: 'La domanda non chiarisce se il numero riguarda i deputati attuali o quelli previsti prima della riforma.', at: now - 4 * DAY, status: 'open', priority: 'media', assignee: null, log: [] },
      { id: 'r2', qid: 'q93', v: 1, by: 'u-reg', reason: 'Duplicato', text: 'Mi sembra uguale a una domanda già vista nello stesso quiz.', at: now - 2 * DAY, status: 'open', priority: 'bassa', assignee: null, log: [] }],
    audit: [
      { at: now - 3 * DAY, actor: 'u-ed', target: 'q90', v: 1, action: 'Creazione bozza', note: '' },
      { at: now - 3 * DAY, actor: 'u-ed2', target: 'q91', v: 1, action: 'Invio in revisione', note: '' },
      { at: now - 2 * DAY, actor: 'u-rev', target: 'q92', v: 1, action: 'Modifiche richieste', note: 'Distinguere nella spiegazione i senatori elettivi da quelli a vita.' },
      { at: now - 2 * DAY, actor: 'u-ed2', target: 'q12', v: 2, action: 'Nuova versione in revisione', note: "Allineata la spiegazione all'art. 97" }] };
  S.recs['u-reg@demo'] = seedRegular(demo);
  return S;
}
let S = null;
/* aggiunge al banco demo le domande introdotte dopo il primo salvataggio, senza toccare quelle esistenti */
function migrate(st) { const qs = st.data.demo.questions; const have = new Set(qs.map(q => q.id)); const missing = buildQuestions().filter(q => !have.has(q.id)); if (!missing.length) return; qs.push(...missing); try { localStorage.setItem(KEY, JSON.stringify(st)); } catch (e) {} }
BL.load = () => { try { S = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (e) { S = null; } if (S && S.schema === 1) migrate(S); if (!S || S.schema !== 1) { S = seed(); try { localStorage.setItem(KEY, JSON.stringify(S)); } catch (e) {} } BL.applyTheme(); return S; };
BL.state = () => S || BL.load();
BL.debug = () => { try { return JSON.parse(sessionStorage.getItem(DEBUG_KEY) || '{}'); } catch (e) { return {}; } };
BL.setDebug = d => sessionStorage.setItem(DEBUG_KEY, JSON.stringify(Object.assign(BL.debug(), d)));
/* commit: applica una mutazione; se il salvataggio fallisce, ripristina l'ultimo stato salvato. */
BL.commit = mut => {
  const backup = localStorage.getItem(KEY);
  try {
    const res = mut(S);
    if (BL.debug().failSave) throw new Error('Errore di salvataggio simulato');
    localStorage.setItem(KEY, JSON.stringify(S));
    return Object.assign({ ok: true }, res && typeof res === 'object' ? res : {});
  } catch (e) { S = JSON.parse(backup || 'null') || seed(); return { ok: false, error: e.message }; }
};
BL.reset = () => { localStorage.removeItem(KEY); S = null; return BL.load(); };
BL.applyTheme = () => { try { document.documentElement.dataset.theme = (S && S.theme) || 'light'; } catch (e) {} };
BL.login = (uid, env) => BL.commit(s => { s.auth = { uid, env, at: Date.now() }; });
BL.logout = () => BL.commit(s => { s.auth = null; });
BL.me = () => { const s = BL.state(); return s.auth ? s.users.find(u => u.id === s.auth.uid) || null : null; };
BL.env = () => (BL.state().auth || {}).env || 'demo';
BL.bank = env => BL.state().data[env || BL.env()];
BL.rec = (uid, env) => { const s = BL.state(); uid = uid || (s.auth && s.auth.uid); env = env || BL.env(); const k = uid + '@' + env; if (!s.recs[k]) s.recs[k] = newRec(); return s.recs[k]; };

/* ---------- CONTENUTI ---------- */
BL.live = q => q.current != null ? q.versions.find(v => v.v === q.current) : null;
BL.working = q => q.versions[q.versions.length - 1];
BL.isLive = q => !q.suspended && !q.mergedInto && q.current != null && !!BL.live(q) && BL.live(q).status === 'published';
BL.versionOf = (bank, qid, v) => { const q = bank.questions.find(x => x.id === qid); return q ? q.versions.find(x => x.v === v) || null : null; };
BL.isDue = v => !!(v && v.nextReview && v.nextReview < todayISO());
BL.isSoon = v => !!(v && v.nextReview && v.nextReview >= todayISO() && v.nextReview <= addDays(todayISO(), 30));
BL.name = (bank, kind, id) => { const x = (bank.taxonomy[kind] || []).find(e => e.id === id); return x ? x.name : '—'; };
BL.publishedMaterials = bank => bank.materials.filter(m => m.status === 'published');
BL.publishedQuizzes = bank => bank.quizzes.filter(z => z.status === 'published');
BL.pool = (bank, f) => {
  f = f || {};
  return bank.questions.filter(BL.isLive).filter(q => { const v = BL.live(q);
    if (f.subjects && f.subjects.length && !f.subjects.includes(v.subject)) return false;
    if (f.topics && f.topics.length && !f.topics.includes(v.topic)) return false;
    if (f.difficulty && f.difficulty !== 'mix' && v.difficulty !== +f.difficulty) return false;
    if (f.profile && !v.profiles.includes(f.profile)) return false;
    return true; });
};
/* distribuzione bilanciata trasparente tra materie */
BL.plan = (bank, f, count) => {
  const pool = BL.pool(bank, f);
  const subs = [...new Set(pool.map(q => BL.live(q).subject))];
  const rows = subs.map(s => { const qs = pool.filter(q => BL.live(q).subject === s); return { id: s, name: BL.name(bank, 'subjects', s), total: qs.length, d1: qs.filter(q => BL.live(q).difficulty === 1).length, d2: qs.filter(q => BL.live(q).difficulty === 2).length, d3: qs.filter(q => BL.live(q).difficulty === 3).length, planned: 0 }; });
  let left = Math.min(count, pool.length);
  while (left > 0) { let moved = false; for (const r of rows) { if (left > 0 && r.planned < r.total) { r.planned++; left--; moved = true; } } if (!moved) break; }
  return { pool, rows, available: pool.length, enough: pool.length >= count && count > 0 };
};
BL.buildQuiz = (bank, cfg, rec) => {
  const p = BL.plan(bank, cfg.filter, cfg.count);
  if (!p.enough) return { ok: false, error: 'insufficient', available: p.available, plan: p };
  const r = rng(Date.now() % 1e9);
  let wrongIds = new Set();
  if (cfg.mode === 'training' && rec) { const answers = rec.attempts.flatMap(a => a.items); if (answers.length >= 30) wrongIds = new Set(answers.filter(i => i.answer != null && !i.correct).map(i => i.qid)); }
  const items = [];
  p.rows.forEach(row => {
    let qs = shuffle(p.pool.filter(q => BL.live(q).subject === row.id), r);
    if (wrongIds.size) qs = qs.filter(q => wrongIds.has(q.id)).concat(qs.filter(q => !wrongIds.has(q.id)));
    qs.slice(0, row.planned).forEach(q => items.push({ qid: q.id, v: q.current }));
  });
  return { ok: true, items: shuffle(items, r), plan: p, prioritized: wrongIds.size > 0 };
};
BL.startSession = cfg => {
  const bank = BL.bank(), rec = BL.rec();
  const b = BL.buildQuiz(bank, cfg, rec);
  if (!b.ok) return b;
  const now = Date.now();
  const isExam = cfg.mode === 'exam';
  const session = {
    id: 's' + now, mode: cfg.mode, title: cfg.title, key: cfg.key,
    items: b.items, answers: {}, revealed: {}, current: 0,
    startedAt: now, deadline: isExam ? now + cfg.durationMin * 60e3 : null, durationMin: cfg.durationMin || null,
    interruptions: [], lastSeen: now, pathRef: cfg.pathRef || null, prioritized: b.prioritized
  };
  const res = BL.commit(() => { rec.session = session; });
  return res.ok ? { ok: true, session } : res;
};
BL.saveSession = patch => {
  const rec = BL.rec();
  return BL.commit(() => { if (rec.session) Object.assign(rec.session, patch, { lastSeen: Date.now() }); });
};
BL.logInterruption = type => {
  const rec = BL.rec();
  if (!rec.session) return;
  BL.commit(() => { rec.session.interruptions.push({ at: Date.now(), type }); });
};
BL.abandonSession = () => {
  const rec = BL.rec();
  return BL.commit(() => {
    const s = rec.session;
    if (!s) return;
    rec.attempts.push({
      id: 'a' + Date.now(), mode: s.mode, title: s.title, key: s.key, startedAt: s.startedAt, finishedAt: Date.now(),
      durationSec: 0, items: [], score: null, reason: 'abandoned', interruptions: s.interruptions, status: 'abandoned'
    });
    rec.session = null;
  });
};
BL.notify = (rec, type, title, body) => {
  const pref = { goal: 'goals', progress: 'progress', content: 'content' }[type];
  if (pref && rec.prefs.notif[pref] === false) return;
  rec.notifications.unshift({ id: 'n' + Date.now() + Math.random().toString(36).slice(2, 5), type, title, body, at: Date.now(), read: false });
};

/* Segna un passo di un percorso come completato (usato da quiz e materiali). */
function markPathStep(rec, pid, sid, at) {
  const p = rec.paths[pid] || (rec.paths[pid] = { order: null, status: {} });
  p.status[sid] = 'done';
  p.at = at;
}

/* XP di un quiz concluso: base 10 + corrette (0 dalla terza ripetizione in 24 ore), più bonus miglioramento in simulazione. */
function xpForAttempt(rec, att) {
  const { score } = att;
  const recent = rec.attempts.filter(a => a.key === att.key && a.status === 'completed' && att.finishedAt - a.finishedAt < DAY).length;
  const xp = [recent >= 2
    ? { amount: 0, reason: 'Ripetizione dello stesso quiz nelle 24 ore: nessun XP aggiuntivo' }
    : { amount: 10 + score.C, reason: 'Quiz completato' }];
  if (att.mode === 'exam') {
    const prev = rec.attempts.filter(a => a.mode === 'exam' && a.status === 'completed' && a.score && a.score.N === score.N).slice(-1)[0];
    if (prev && score.score > prev.score.score) xp.push({ amount: 15, reason: 'Miglioramento in simulazione comparabile' });
  }
  return xp;
}

BL.finishSession = reason => {
  const rec = BL.rec(), bank = BL.bank();
  const s = rec.session;
  if (!s) return { ok: false, error: 'Nessuna sessione attiva' };
  const end = s.deadline && reason === 'timeout' ? Math.min(Date.now(), s.deadline) : Date.now();
  const items = s.items.map(it => {
    const v = BL.versionOf(bank, it.qid, it.v);
    const answer = s.answers[it.qid] == null ? null : s.answers[it.qid];
    return { qid: it.qid, v: it.v, answer, correct: answer != null && !!v && answer === v.correct };
  });
  const score = BL.scoreItems(items);
  const att = {
    id: 'a' + Date.now(), mode: s.mode, title: s.title, key: s.key, startedAt: s.startedAt, finishedAt: end,
    durationSec: Math.round((end - s.startedAt) / 1000), items, score, reason,
    interruptions: s.interruptions, status: 'completed', pathRef: s.pathRef
  };
  const xp = xpForAttempt(rec, att);
  const earnedBefore = BL.badges(rec).filter(b => b.earned).map(b => b.id);
  const res = BL.commit(() => {
    rec.attempts.push(att);
    rec.session = null;
    xp.forEach(x => rec.xpLog.push({ at: end, amount: x.amount, reason: x.reason }));
    if (s.pathRef) markPathStep(rec, s.pathRef.pid, s.pathRef.sid, end);
    const total = xp.reduce((a, b) => a + b.amount, 0);
    BL.notify(rec, 'progress', att.mode === 'exam' ? 'Simulazione consegnata' : 'Quiz completato',
      `${att.title}: ${score.display}/30` + (xp[0].amount ? ` · +${total} XP` : ''));
    BL.badges(rec).filter(b => b.earned && !earnedBefore.includes(b.id))
      .forEach(b => BL.notify(rec, 'progress', 'Nuovo badge', `Hai ottenuto il badge «${b.name}».`));
  });
  return res.ok ? { ok: true, attempt: att, xp } : res;
};
/* ripresa: se la simulazione è scaduta, viene consegnata con le risposte salvate */
BL.checkSession = () => {
  const rec = BL.rec();
  const s = rec.session;
  if (!s) return { state: 'none' };
  if (s.mode === 'exam' && Date.now() >= s.deadline) {
    const r = BL.finishSession('timeout');
    return { state: 'expired', attempt: r.attempt, ok: r.ok };
  }
  return { state: 'active', session: s };
};
BL.completeMaterial = mid => {
  const rec = BL.rec(), bank = BL.bank();
  return BL.commit(() => {
    if (rec.completed[mid]) return;
    const now = Date.now();
    rec.completed[mid] = now;
    rec.xpLog.push({ at: now, amount: 8, reason: 'Materiale completato' });
    bank.paths.forEach(p => p.steps.forEach(st => {
      if (st.type === 'material' && st.ref === mid) markPathStep(rec, p.id, st.id, now);
    }));
  });
};
BL.markReviewed = aid => {
  const rec = BL.rec();
  if (rec.reviewed[aid]) return { ok: true, already: true };
  return BL.commit(() => { rec.reviewed[aid] = true; rec.xpLog.push({ at: Date.now(), amount: 5, reason: 'Revisione degli errori' }); });
};

/* ---------- PROGRESSI, GAMIFICATION ---------- */
BL.xp = rec => rec.xpLog.reduce((a, b) => a + b.amount, 0);
BL.level = xp => { const lv = 1 + Math.floor(xp / 150); return { level: lv, into: xp % 150, need: 150, pct: (xp % 150) / 150 }; };
BL.activityDays = rec => new Set(rec.attempts.filter(a => a.status === 'completed').map(a => iso(a.finishedAt)).concat(Object.values(rec.completed).map(t => iso(t))));
BL.streak = rec => { const days = BL.activityDays(rec); let d = todayISO(); if (!days.has(d)) d = addDays(d, -1); let n = 0; while (days.has(d)) { n++; d = addDays(d, -1); } return { days: n, today: days.has(todayISO()) }; };
BL.todayAnswers = rec => rec.attempts.filter(a => a.status === 'completed' && iso(a.finishedAt) === todayISO()).reduce((n, a) => n + a.items.filter(i => i.answer != null).length, 0);
BL.badges = rec => { const done = rec.attempts.filter(a => a.status === 'completed'); return [
  { id: 'first', name: 'Primo quiz', desc: 'Completa il primo quiz.', earned: done.length >= 1 },
  { id: 'ten', name: 'Dieci quiz', desc: 'Completa dieci quiz.', earned: done.length >= 10 },
  { id: 'review', name: 'Revisione attenta', desc: 'Rivedi gli errori di tre quiz.', earned: Object.keys(rec.reviewed).length >= 3 },
  { id: 'streak3', name: 'Tre giorni di fila', desc: 'Studia per tre giorni consecutivi.', earned: BL.streak(rec).days >= 3 },
  { id: 'improve', name: 'In miglioramento', desc: 'Migliora in una simulazione comparabile.', earned: rec.xpLog.some(x => x.reason.startsWith('Miglioramento')) },
  { id: 'reader', name: 'Lettura costante', desc: 'Completa tre materiali.', earned: Object.keys(rec.completed).length >= 3 }]; };
BL.MIN_ANSWERS = 30; BL.MIN_SUBJECT = 20;
BL.stats = (rec, bank, f) => {
  f = f || {}; const now = Date.now(); const since = f.period === '7' ? now - 7 * DAY : f.period === '30' ? now - 30 * DAY : 0;
  const atts = rec.attempts.filter(a => a.status === 'completed' && a.finishedAt >= since && (!f.mode || f.mode === 'all' || a.mode === f.mode)).sort((a, b) => a.finishedAt - b.finishedAt);
  const ans = [];
  atts.forEach(a => a.items.forEach(it => { const v = BL.versionOf(bank, it.qid, it.v); if (!v) return; if (f.subject && f.subject !== 'all' && v.subject !== f.subject) return; ans.push(Object.assign({ subject: v.subject, topic: v.topic, at: a.finishedAt, mode: a.mode }, it)); }));
  const given = ans.filter(x => x.answer != null);
  const acc = list => { const g = list.filter(x => x.answer != null); return g.length ? g.filter(x => x.correct).length / g.length : null; };
  const recent = ans.filter(x => x.at >= now - 30 * DAY);
  const bySubject = bank.taxonomy.subjects.map(s => { const l = ans.filter(x => x.subject === s.id); const lr = recent.filter(x => x.subject === s.id && x.answer != null); const a = acc(l); const ar = acc(lr);
    const readiness = lr.length >= BL.MIN_SUBJECT ? { level: ar >= .75 ? 'Avanzato' : ar >= .5 ? 'Intermedio' : 'Base', reliable: lr.length >= 40 ? 'media' : 'bassa', n: lr.length } : null;
    return { id: s.id, name: s.name, n: l.length, given: l.filter(x => x.answer != null).length, correct: l.filter(x => x.correct).length, acc: a, readiness }; }).filter(s => s.n > 0);
  const weakTopics = bank.taxonomy.topics.map(t => { const l = ans.filter(x => x.topic === t.id); return { id: t.id, subject: t.subject, name: t.name, n: l.length, acc: acc(l) }; }).filter(t => t.n >= 5 && t.acc != null && t.acc < .6).sort((a, b) => a.acc - b.acc);
  const tr = atts.filter(a => a.mode === 'training'), ex = atts.filter(a => a.mode === 'exam');
  const mean = l => l.length ? l.reduce((s, a) => s + a.score.score, 0) / l.length : null;
  return { attempts: atts, nAttempts: atts.length, nAnswers: ans.length, nGiven: given.length, accuracy: acc(ans), bySubject, weakTopics, enough: given.length >= BL.MIN_ANSWERS,
    training: { n: tr.length, acc: acc(tr.flatMap(a => a.items)), mean: mean(tr) }, exam: { n: ex.length, mean: mean(ex), best: ex.length ? Math.max(...ex.map(a => a.score.score)) : null, list: ex } };
};

/* ---------- RICERCA ---------- */
const norm = s => (s || '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');
function lev(a, b) { if (Math.abs(a.length - b.length) > 1) return 2; const m = []; for (let i = 0; i <= a.length; i++) { m[i] = [i]; for (let j = 1; j <= b.length; j++) m[i][j] = i ? Math.min(m[i - 1][j] + 1, m[i][j - 1] + 1, m[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)) : j; } return m[a.length][b.length]; }
const match = (q, hay) => { const h = norm(hay); const words = h.split(/[^a-z0-9]+/); return norm(q).split(/\s+/).filter(Boolean).every(t => h.includes(t) || (t.length >= 4 && words.some(w => lev(t, w) <= 1))); };
BL.search = (bank, q, cat) => {
  if (!q || !q.trim()) return [];
  const pm = BL.publishedMaterials(bank), pq = bank.questions.filter(BL.isLive).map(BL.live);
  const hasSub = id => pm.some(m => m.subject === id) || pq.some(v => v.subject === id);
  const hasTop = id => pm.some(m => m.topic === id) || pq.some(v => v.topic === id);
  const hasProf = id => pm.some(m => m.profiles.includes(id)) || pq.some(v => v.profiles.includes(id));
  const hasEnt = id => pm.some(m => m.entities.includes(id)) || pq.some(v => v.entities.includes(id));
  const T = bank.taxonomy;
  const groups = [
    { id: 'quiz', label: 'Quiz', items: BL.publishedQuizzes(bank).filter(z => match(q, z.title)).map(z => ({ id: z.id, title: z.title, sub: (z.mode === 'exam' ? 'Simulazione' : 'Allenamento') + ' · ' + z.count + ' domande', target: { screen: 'quiz', quiz: z.id } })) },
    { id: 'topics', label: 'Materie e argomenti', items: T.subjects.filter(s => hasSub(s.id) && match(q, s.name)).map(s => ({ id: s.id, title: s.name, sub: 'Materia', target: { screen: 'library', subject: s.id } })).concat(T.topics.filter(t => hasTop(t.id) && match(q, t.name)).map(t => ({ id: t.id, title: t.name, sub: 'Argomento · ' + BL.name(bank, 'subjects', t.subject), target: { screen: 'library', subject: t.subject } }))) },
    { id: 'profiles', label: 'Profili', items: T.profiles.filter(p => hasProf(p.id) && match(q, p.name)).map(p => ({ id: p.id, title: p.name, sub: 'Profilo professionale', target: { screen: 'library', profile: p.id } })) },
    { id: 'entities', label: 'Enti', items: T.entities.filter(e => hasEnt(e.id) && match(q, e.name)).map(e => ({ id: e.id, title: e.name, sub: BL.name(bank, 'areas', e.area), target: { screen: 'library', area: e.area } })) },
    { id: 'materials', label: 'Materiali', items: pm.filter(m => match(q, m.title + ' ' + m.keyConcepts.join(' ') + ' ' + BL.name(bank, 'topics', m.topic))).map(m => ({ id: m.id, title: m.title, sub: BL.FORMAT[m.format] + ' · ' + BL.name(bank, 'subjects', m.subject), target: { screen: 'reader', material: m.id } })) }];
  return groups.filter(g => (!cat || cat === 'all' || g.id === cat) && g.items.length);
};

/* ---------- PERMESSI E WORKFLOW EDITORIALE ---------- */
/* Nel prototipo i controlli sono solo lato client. In produzione vanno imposti dal backend. */
const PERMS = {
  user: [],
  editor: ['q.create', 'q.edit', 'q.submit', 'm.edit', 'z.edit'],
  reviewer: ['q.review', 'q.publish', 'q.suspend', 'q.verify', 'r.handle', 'r.assign', 'dup.decide', 'm.review', 'z.publish'],
  admin: ['q.create', 'q.edit', 'q.submit', 'q.review', 'q.publish', 'q.suspend', 'q.verify', 'r.handle', 'r.assign', 'dup.decide', 'm.edit', 'm.review', 'z.edit', 'z.publish', 'tax.edit', 'users.edit', 'settings.edit']
};
BL.PERMS = PERMS;
BL.can = (user, action, target) => {
  const role = user && user.role; if (!(PERMS[role] || []).includes(action)) return { ok: false, why: `Il ruolo ${BL.ROLES[role] || 'ospite'} non è autorizzato a questa azione.` };
  if (target && (action === 'q.review' || action === 'm.review')) { const w = target.versions ? BL.working(target) : target; if (w.author === user.id && role !== 'admin') return { ok: false, why: 'Non puoi revisionare o approvare un contenuto di cui sei autore. Solo un amministratore può farlo.' }; }
  return { ok: true };
};
BL.validate = (v, settings) => {
  const e = {};
  if (!v.text || v.text.trim().length < 10) e.text = 'Inserisci il testo della domanda (almeno 10 caratteri).';
  const filled = v.options.filter(o => o && o.trim()); if (filled.length < 4) e.options = 'Compila tutte e quattro le opzioni di risposta.';
  if (v.correct == null || !(v.options[v.correct] || '').trim()) e.correct = 'Indica la risposta corretta tra le opzioni compilate.';
  if (settings.requireExplanation && (!v.explanation || v.explanation.trim().length < 10)) e.explanation = 'La spiegazione è obbligatoria secondo la policy editoriale.';
  if (!v.subject) e.subject = 'Seleziona la materia.'; if (!v.topic) e.topic = "Seleziona l'argomento.";
  if (!v.difficulty) e.difficulty = 'Assegna manualmente la difficoltà.';
  if (!v.source || !v.source.trim()) e.source = 'Indica la fonte ufficiale o documentale.';
  if (settings.requireUrl && !/^https?:\/\//.test(v.sourceUrl || '')) e.sourceUrl = "Inserisci l'URL della fonte (http/https).";
  if (!v.lastVerified) e.lastVerified = "Indica la data dell'ultima verifica.";
  if (!v.nextReview) e.nextReview = 'Indica la data della prossima revisione.'; else if (v.lastVerified && v.nextReview <= v.lastVerified) e.nextReview = "La prossima revisione deve essere successiva all'ultima verifica.";
  return e;
};
const audit = (s, actor, target, v, action, note) => s.audit.unshift({ at: Date.now(), actor: actor.id, target, v, action, note: note || '' });
BL.createQuestion = actor => {
  const c = BL.can(actor, 'q.create');
  if (!c.ok) return c;
  const id = 'q' + Date.now().toString(36);
  return BL.commit(s => {
    const q = { id, demo: true, suspended: false, mergedInto: null, current: null, versions: [blankVersion(actor.id)] };
    BL.bank('demo').questions.unshift(q);
    audit(s, actor, id, 1, 'Creazione bozza');
    return { id };
  });
};
BL.updateDraft = (actor, qid, fields) => {
  const c = BL.can(actor, 'q.edit'); if (!c.ok) return c;
  const q = BL.bank('demo').questions.find(x => x.id === qid); if (!q) return { ok: false, why: 'Domanda non trovata.' };
  const w = BL.working(q);
  if (!['draft', 'changes'].includes(w.status)) return { ok: false, why: 'Solo le bozze o i contenuti con modifiche richieste sono modificabili.' };
  return BL.commit(() => { Object.assign(w, fields); if (fields.subject !== undefined) Object.assign(w, derive(BL.bank('demo').taxonomy, w.subject)); w.updatedAt = Date.now(); w.updatedBy = actor.id; });
};
/* Transizioni editoriali delle domande: permesso richiesto, controllo dello stato di partenza e effetto sulla versione di lavoro.
   `check` restituisce un messaggio di errore oppure null; `apply` modifica w (versione di lavoro) e q (domanda). */
const Q_TRANSITIONS = {
  submit: {
    perm: 'q.submit', label: 'Invio in revisione',
    check: (c) => !['draft', 'changes'].includes(c.w.status) ? 'Solo una bozza può essere inviata in revisione.' : null,
    apply: (c) => { c.w.status = 'review'; c.w.reviewNote = ''; }
  },
  approve: {
    perm: 'q.review', reviewer: true, label: 'Approvazione',
    check: (c) => c.w.status !== 'review' ? 'Il contenuto non è in revisione.' : null,
    apply: (c) => { Object.assign(c.w, { status: 'approved', reviewer: c.actor.id, approvedAt: Date.now() }); }
  },
  changes: {
    perm: 'q.review', reviewer: true, label: 'Modifiche richieste',
    check: (c) => c.w.status !== 'review' ? 'Il contenuto non è in revisione.' : !(c.note || '').trim() ? 'Specifica le modifiche richieste.' : null,
    apply: (c) => { Object.assign(c.w, { status: 'changes', reviewer: c.actor.id, reviewNote: c.note }); }
  },
  reject: {
    perm: 'q.review', reviewer: true, label: 'Rifiuto',
    check: (c) => c.w.status !== 'review' ? 'Il contenuto non è in revisione.' : null,
    apply: (c) => { Object.assign(c.w, { status: 'rejected', reviewer: c.actor.id, reviewNote: c.note || '' }); }
  },
  publish: {
    perm: 'q.publish', label: 'Pubblicazione',
    check: (c) => c.w.status !== 'approved' ? 'Si possono pubblicare soltanto contenuti approvati.' : null,
    apply: (c) => {
      const prev = BL.live(c.q);
      if (prev && prev !== c.w) prev.status = 'superseded';
      Object.assign(c.w, { status: 'published', publishedAt: Date.now(), publishedBy: c.actor.id });
      c.q.current = c.w.v;
    }
  },
  newVersion: {
    perm: 'q.edit', label: 'Nuova versione in bozza', auditVersion: (c) => c.w.v + 1,
    check: (c) => c.w.status !== 'published' ? 'Esiste già una versione in lavorazione.' : null,
    apply: (c) => {
      c.q.versions.push(Object.assign(clone(c.w), {
        v: c.w.v + 1, status: 'draft', author: c.actor.id, reviewer: null, createdAt: Date.now(),
        publishedAt: null, note: c.note || 'Modifica della versione pubblicata', reviewNote: ''
      }));
    }
  },
  suspend: {
    perm: 'q.suspend', label: 'Sospensione dai nuovi quiz',
    check: (c) => !(c.note || '').trim() ? 'Indica il motivo della sospensione.' : null,
    apply: (c) => { c.q.suspended = true; c.q.suspendNote = c.note; }
  },
  unsuspend: {
    perm: 'q.suspend', label: 'Revoca della sospensione',
    apply: (c) => { c.q.suspended = false; }
  },
  verify: {
    perm: 'q.verify', label: 'Verifica normativa completata',
    check: (c) => !BL.live(c.q) ? 'Nessuna versione pubblicata da verificare.' : null,
    apply: (c) => {
      const v = BL.live(c.q);
      v.lastVerified = todayISO();
      v.nextReview = addDays(todayISO(), Math.round(c.settings.verifyMonths * 30.4));
    }
  },
  reopen: {
    perm: 'q.edit', label: 'Riapertura come bozza',
    check: (c) => c.w.status !== 'rejected' ? 'Solo un contenuto rifiutato può essere riaperto.' : null,
    apply: (c) => { c.w.status = 'draft'; }
  }
};
BL.transition = (actor, qid, action, note) => {
  const s = BL.state();
  const q = BL.bank('demo').questions.find(x => x.id === qid);
  if (!q) return { ok: false, why: 'Domanda non trovata.' };
  const rule = Q_TRANSITIONS[action];
  if (!rule) return { ok: false, why: 'Azione non valida.' };
  const perm = BL.can(actor, rule.perm, rule.reviewer ? q : null);
  if (!perm.ok) return perm;
  const ctx = { actor, q, w: BL.working(q), note, settings: s.settings };
  const why = rule.check && rule.check(ctx);
  if (why) return { ok: false, why };
  if (action === 'submit') {
    const errors = BL.validate(ctx.w, s.settings);
    if (Object.keys(errors).length) return { ok: false, why: 'Completa i campi obbligatori.', errors };
  }
  const auditV = rule.auditVersion ? rule.auditVersion(ctx) : ctx.w.v;
  return BL.commit(st => {
    rule.apply(ctx);
    audit(st, actor, qid, auditV, rule.label, note);
  });
};
BL.materialTransition = (actor, mid, action) => {
  const m = BL.bank('demo').materials.find(x => x.id === mid); if (!m) return { ok: false, why: 'Materiale non trovato.' };
  const need = { submit: 'm.edit', approve: 'm.review', publish: 'm.review', unpublish: 'm.review' }[action];
  if (!need) return { ok: false, why: 'Azione non valida.' };
  const c = BL.can(actor, need, ['approve'].includes(action) ? m : null); if (!c.ok) return c;
  const ok = { submit: ['draft'], approve: ['review'], publish: ['approved'], unpublish: ['published'] }[action]; if (!ok.includes(m.status)) return { ok: false, why: 'Transizione non consentita dallo stato attuale.' };
  if (action === 'submit' || action === 'publish') { const e = BL.validateMaterial(m, !!BL.getFile(m.id) || !!m.demo && m.format !== 'scheda' && !m.createdAt); if (Object.keys(e).length) return { ok: false, why: 'Completa i campi obbligatori del materiale: ' + Object.values(e).join(' '), errors: e }; }
  return BL.commit(s => { m.status = { submit: 'review', approve: 'approved', publish: 'published', unpublish: 'draft' }[action]; audit(s, actor, mid, 1, 'Materiale: ' + { submit: 'invio in revisione', approve: 'approvazione', publish: 'pubblicazione', unpublish: 'ritiro dalla pubblicazione' }[action]); });
};
BL.report = (qid, v, reason, text) => {
  const s = BL.state();
  return BL.commit(() => {
    s.reports.unshift({ id: 'r' + Date.now(), qid, v, by: s.auth.uid, reason, text, at: Date.now(), status: 'open', priority: 'media', assignee: null, log: [] });
    BL.notify(BL.rec(), 'content', 'Segnalazione inviata', 'La segnalazione è in coda di revisione. Riceverai un avviso quando verrà gestita.');
  });
};
BL.updateReport = (actor, rid, patch, label) => {
  const c = BL.can(actor, patch.status ? 'r.handle' : 'r.assign');
  if (!c.ok) return c;
  return BL.commit(s => {
    const r = s.reports.find(x => x.id === rid);
    Object.assign(r, patch);
    r.log.push({ at: Date.now(), actor: actor.id, label });
    audit(s, actor, r.qid, r.v, 'Segnalazione ' + rid + ': ' + label);
    if (patch.status === 'resolved' && s.recs[r.by + '@demo']) {
      BL.notify(s.recs[r.by + '@demo'], 'content', 'Segnalazione gestita', 'Il team editoriale ha gestito la tua segnalazione.');
    }
  });
};
BL.quizChecks = (bank, z, settings) => {
  const all = bank.questions.filter(q => { const v = BL.live(q) || BL.working(q); return (!z.filter.subjects || z.filter.subjects.includes(v.subject)) && (!z.filter.topics || z.filter.topics.includes(v.topic)); });
  const live = all.filter(BL.isLive).map(BL.live); const susp = all.filter(q => q.suspended).length; const notApproved = all.filter(q => !BL.isLive(q) && !q.suspended).length;
  const T = bank.taxonomy; const assocOk = (z.filter.subjects || []).every(s => T.subjects.some(x => x.id === s)) && (z.filter.topics || []).every(t => T.topics.some(x => x.id === t));
  const noUrl = live.filter(v => !v.source || (settings.requireUrl && !v.sourceUrl)).length;
  return [
    { label: 'Domande approvate e pubblicate', ok: live.length > 0, detail: `${live.length} pubblicate · ${notApproved} non approvate escluse` },
    { label: 'Numero di domande sufficiente', ok: live.length >= z.count, detail: `${live.length} disponibili su ${z.count} richieste` },
    { label: 'Risposte corrette presenti', ok: live.every(v => v.correct != null), detail: 'Verificato su tutte le domande pubblicate' },
    { label: 'Spiegazioni disponibili', ok: !settings.requireExplanation || live.every(v => v.explanation), detail: settings.requireExplanation ? 'Obbligatorie per policy' : 'Facoltative per policy' },
    { label: 'Fonti compilate secondo la policy', ok: noUrl === 0, detail: noUrl ? `${noUrl} domande senza fonte o URL completo` : 'Tutte compilate' },
    { label: 'Associazioni valide', ok: assocOk, detail: assocOk ? 'Materie e argomenti presenti nel catalogo' : 'Riferimenti a voci inesistenti' },
    { label: 'Nessun riferimento a contenuti sospesi', ok: true, detail: susp ? `${susp} domande sospese escluse automaticamente` : 'Nessuna domanda sospesa' }];
};
BL.duplicates = bank => { const tok = t => new Set(norm(t).split(/[^a-z0-9]+/).filter(w => w.length > 3)); const qs = bank.questions.filter(q => !q.mergedInto); const out = [];
  /* similarità = 50% testo (Jaccard) + 25% stessa fonte + 25% stessa risposta corretta; solo nello stesso argomento */
  for (let i = 0; i < qs.length; i++) for (let j = i + 1; j < qs.length; j++) { const va = BL.working(qs[i]), vb = BL.working(qs[j]); if (!va.topic || va.topic !== vb.topic) continue;
    const a = tok(va.text), b = tok(vb.text); const inter = [...a].filter(x => b.has(x)).length; const jac = inter / (a.size + b.size - inter || 1);
    const sameSrc = va.source && norm(va.source) === norm(vb.source) ? 1 : 0; const ca = va.options[va.correct], cb = vb.options[vb.correct]; const sameAns = ca && cb && norm(ca) === norm(cb) ? 1 : 0;
    const sim = .5 * jac + .25 * sameSrc + .25 * sameAns; if (sim >= .45) out.push({ a: qs[i].id, b: qs[j].id, sim }); }
  return out.sort((x, y) => y.sim - x.sim); };
BL.decideDuplicate = (actor, a, b, decision, note) => {
  const c = BL.can(actor, 'dup.decide');
  if (!c.ok) return c;
  return BL.commit(s => {
    const bank = BL.bank('demo');
    s.dupDecisions = s.dupDecisions || {};
    s.dupDecisions[a + '|' + b] = { decision, at: Date.now(), actor: actor.id, note };
    if (decision === 'merge') {
      const qa = bank.questions.find(q => q.id === a), qb = bank.questions.find(q => q.id === b);
      qb.mergedInto = a;
      const la = BL.live(qa) || BL.working(qa), lb = BL.live(qb) || BL.working(qb);
      la.profiles = [...new Set(la.profiles.concat(lb.profiles))];
      la.entities = [...new Set(la.entities.concat(lb.entities))];
    }
    audit(s, actor, a, null, decision === 'merge' ? `Consolidamento: ${b} confluita in ${a}` : `Duplicato: mantenute entrambe (${a}, ${b})`, note);
  });
};
BL.taxEdit = (actor, kind, id, patch) => {
  const c = BL.can(actor, 'tax.edit');
  if (!c.ok) return c;
  return BL.commit(s => {
    const list = BL.bank('demo').taxonomy[kind];
    if (id) Object.assign(list.find(x => x.id === id), patch);
    else { id = kind[0] + '-' + Date.now().toString(36); list.push(Object.assign({ id }, patch)); }
    audit(s, actor, id, null, 'Catalogo: ' + (patch.name ? `«${patch.name}»` : 'modifica'), kind);
  });
};
BL.setRole = (actor, uid, role) => {
  const c = BL.can(actor, 'users.edit');
  if (!c.ok) return c;
  const admins = BL.state().users.filter(u => u.role === 'admin').length;
  if (uid === actor.id && role !== 'admin' && admins <= 1) return { ok: false, why: "Non puoi rimuovere il ruolo dall'unico amministratore." };
  return BL.commit(st => {
    st.users.find(u => u.id === uid).role = role;
    audit(st, actor, uid, null, 'Ruolo modificato: ' + BL.ROLES[role]);
  });
};
BL.userName = uid => { const u = BL.state().users.find(x => x.id === uid); return u ? u.name : uid || '—'; };

/* ---------- MATERIALI: CREAZIONE, IMPORTAZIONE, FILE ---------- */
const FILES_KEY = 'bandolab.files.v1';
BL.MAX_FILE = 3 * 1024 * 1024;
const readFiles = () => { try { return JSON.parse(localStorage.getItem(FILES_KEY) || '{}'); } catch (e) { return {}; } };
BL.getFile = mid => readFiles()[mid] || null;
BL.storeFile = (mid, file) => { const all = readFiles(); all[mid] = file; try { localStorage.setItem(FILES_KEY, JSON.stringify(all)); return { ok: true }; } catch (e) { return { ok: false, error: 'Spazio del browser insufficiente per salvare il file (limite del prototipo).' }; } };
BL.removeFile = mid => { const all = readFiles(); delete all[mid]; localStorage.setItem(FILES_KEY, JSON.stringify(all)); };
BL.validateMaterial = (m, hasFile) => {
  const e = {};
  if (!m.title || m.title.trim().length < 4) e.title = 'Inserisci un titolo (almeno 4 caratteri).';
  if (!m.subject) e.subject = 'Seleziona la materia.'; if (!m.topic) e.topic = "Seleziona l'argomento.";
  if (!m.source || !m.source.trim()) e.source = 'Indica la fonte.';
  if (!m.lastVerified) e.lastVerified = "Indica la data dell'ultima verifica.";
  if (!m.nextReview) e.nextReview = 'Indica la data della prossima revisione.'; else if (m.lastVerified && m.nextReview <= m.lastVerified) e.nextReview = "Deve essere successiva all'ultima verifica.";
  if (m.format === 'scheda' && !m.sections.some(s => s.title.trim() && s.body.trim().length >= 20)) e.sections = 'Aggiungi almeno una sezione con titolo e testo (20 caratteri).';
  if (m.format !== 'scheda' && !hasFile) e.file = 'Carica il file PDF.';
  return e;
};
BL.createMaterial = actor => { const c = BL.can(actor, 'm.edit'); if (!c.ok) return c; const id = 'm' + Date.now().toString(36);
  return BL.commit(s => { BL.bank('demo').materials.unshift({ id, title: '', subject: '', topic: '', format: 'scheda', minutes: 5, source: '', keyConcepts: [], related: [], sections: [], status: 'draft', demo: true, author: actor.id, lastVerified: todayISO(), nextReview: addDays(todayISO(), 365), profiles: [], entities: [], createdAt: Date.now() }); audit(s, actor, id, 1, 'Materiale: creazione bozza'); return { id }; }); };
BL.updateMaterial = (actor, mid, fields) => {
  const c = BL.can(actor, 'm.edit'); if (!c.ok) return c; const bank = BL.bank('demo'); const m = bank.materials.find(x => x.id === mid);
  if (!m) return { ok: false, why: 'Materiale non trovato.' }; if (m.status !== 'draft') return { ok: false, why: 'Solo i materiali in bozza sono modificabili. Ritira il materiale per modificarlo.' };
  return BL.commit(() => { Object.assign(m, fields); m.sections = (m.sections || []).map((s, i) => ({ id: s.id || mid + '-s' + (i + 1) + '-' + Date.now().toString(36), title: s.title, body: s.body })); Object.assign(m, derive(bank.taxonomy, m.subject)); m.updatedAt = Date.now(); m.updatedBy = actor.id; });
};
/* Testo strutturato: "# Titolo", "## Sezione", elenco "- " sotto "## Concetti chiave" */
BL.parseText = text => {
  const out = { title: '', sections: [], keyConcepts: [] }; let cur = null, inKey = false;
  String(text || '').replace(/\r/g, '').split('\n').forEach(raw => { const line = raw.trim();
    if (/^#\s+/.test(line) && !/^##/.test(line)) { if (!out.title) out.title = line.replace(/^#\s+/, ''); return; }
    if (/^##+\s+/.test(line)) { const t = line.replace(/^##+\s+/, ''); inKey = /^concetti chiave/i.test(t); if (!inKey) { cur = { title: t, body: '' }; out.sections.push(cur); } return; }
    if (inKey) { if (/^[-*•]\s+/.test(line)) out.keyConcepts.push(line.replace(/^[-*•]\s+/, '')); return; }
    if (!line) { if (cur && cur.body && !cur.body.endsWith('\n\n')) cur.body += '\n\n'; return; }
    if (!cur) { cur = { title: 'Introduzione', body: '' }; out.sections.push(cur); }
    cur.body += (cur.body && !cur.body.endsWith('\n') ? ' ' : '') + line; });
  out.sections.forEach(s => { s.body = s.body.trim(); });
  out.sections = out.sections.filter(s => s.title || s.body);
  return out;
};
const loadJSZip = () => window.JSZip ? Promise.resolve(window.JSZip) : new Promise((res, rej) => { const sc = document.createElement('script'); sc.src = 'https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js'; sc.onload = () => res(window.JSZip); sc.onerror = () => rej(new Error('Impossibile caricare il lettore DOCX (connessione assente?).')); document.head.appendChild(sc); });
/* DOCX: gli stili Titolo 1 / Heading 1 diventano il titolo, Titolo 2 / Heading 2 le sezioni */
BL.parseDocx = async buf => {
  const JSZip = await loadJSZip(); const zip = await JSZip.loadAsync(buf); const f = zip.file('word/document.xml'); if (!f) throw new Error('File DOCX non valido.');
  const doc = new DOMParser().parseFromString(await f.async('string'), 'application/xml'); const W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  const lines = [...doc.getElementsByTagNameNS(W, 'p')].map(p => { const st = p.getElementsByTagNameNS(W, 'pStyle')[0]; const style = st ? (st.getAttributeNS(W, 'val') || st.getAttribute('w:val') || '') : ''; const isList = p.getElementsByTagNameNS(W, 'numPr').length > 0;
    const txt = [...p.getElementsByTagNameNS(W, 't')].map(t => t.textContent).join('');
    if (/^(heading|titolo)1$|^title$/i.test(style.replace(/\s/g, ''))) return '# ' + txt; if (/^(heading|titolo)[2-6]$/i.test(style.replace(/\s/g, ''))) return '## ' + txt; return (isList ? '- ' : '') + txt; });
  return BL.parseText(lines.join('\n'));
};
BL.readFileAsDataURL = file => new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = () => rej(new Error('Lettura del file non riuscita.')); r.readAsDataURL(file); });

/* ---------- INTEGRAZIONI ---------- */
BL.INTEGRATIONS = [
  { name: 'Calcolo del punteggio e test', status: 'Implementato', note: 'Funzione unica computeScore con 10 test eseguibili.' },
  { name: 'Quiz, simulazioni, risultati, revisione', status: 'Implementato', note: 'Funzionanti nel browser con dati demo.' },
  { name: 'Persistenza', status: 'Simulato', note: 'localStorage del browser: dati locali, cancellabili, non condivisi tra dispositivi.' },
  { name: 'Accesso con Google (OAuth)', status: 'Simulato', note: 'Nessuna connessione a Google. Richiede client ID e backend.' },
  { name: 'Timer e protezione simulazioni', status: 'Simulato', note: 'Scadenza salvata in locale: protegge dal ricaricamento, non da manomissioni. Serve validazione server.' },
  { name: 'Ruoli e permessi', status: 'Simulato', note: 'Verificati solo nel client. In produzione vanno imposti dal backend.' },
  { name: 'Esportazione dati', status: 'Simulato', note: 'Scarica i dati locali del prototipo; non esiste una richiesta al server.' },
  { name: 'Eliminazione account', status: 'Simulato', note: 'Elimina solo i dati locali di questo browser.' },
  { name: 'Notifiche in-app', status: 'Simulato', note: 'Generate da eventi locali; nessun servizio persistente.' },
  { name: 'Importazione materiali (testo, DOCX, PDF)', status: 'Implementato', note: 'Analisi nel browser. I PDF (max 3 MB) sono salvati in locale; in produzione andranno su uno storage.' },
  { name: 'Lettore PDF', status: 'Implementato', note: 'Visualizza e scarica i PDF caricati. I PDF demo preesistenti non hanno file.' },
  { name: 'Database, API, audit server-side', status: 'Da sviluppare', note: 'Interfacce dati pronte per essere sostituite da servizi remoti.' }];

window.BL = BL;
try { const t = JSON.parse(localStorage.getItem(KEY) || '{}').theme; document.documentElement.dataset.theme = t || 'light'; } catch (e) {}
})();
