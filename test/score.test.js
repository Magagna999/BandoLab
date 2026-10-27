'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadCore, T0, DAY } = require('./helpers/core');

test('punteggio: i 10 casi integrati nel core passano', () => {
  const { BL } = loadCore();
  const res = BL.runScoreTests();
  assert.equal(res.length, 10);
  res.forEach(r => assert.ok(r.pass, `${r.name}: ${r.detail}`));
});

test('punteggio: formula C - 0,5E - 0,25O su scala 30', () => {
  const { BL } = loadCore();
  const r = BL.computeScore(3, 1, 1, 5);
  assert.equal(r.raw, 2.25);
  assert.equal(r.score, 13.5);
  assert.equal(r.display, '13,5');
  assert.equal(r.passed, false);
});

test('punteggio: soglia di superamento 21 sul valore non arrotondato', () => {
  const { BL } = loadCore();
  assert.equal(BL.computeScore(16, 4, 0, 20).passed, true);
  const near = BL.computeScore(130, 5, 35, 170);
  assert.equal(near.display, '21,0');
  assert.equal(near.passed, false);
});

test('punteggio: limiti 0 e 30, quiz vuoto', () => {
  const { BL } = loadCore();
  assert.equal(BL.computeScore(0, 10, 0, 10).score, 0);
  assert.equal(BL.computeScore(10, 0, 0, 10).score, 30);
  const empty = BL.computeScore(0, 0, 0, 0);
  assert.equal(empty.empty, true);
  assert.equal(empty.passed, false);
});

test('punteggio: valori incoerenti o non interi sollevano errore', () => {
  const { BL } = loadCore();
  assert.throws(() => BL.computeScore(3, 3, 3, 5), /uguale a N/);
  assert.throws(() => BL.computeScore(1.5, 0, 0, 1.5), /non validi/);
  assert.throws(() => BL.computeScore(-1, 1, 0, 0), /non validi/);
});

test('scoreItems: conta corrette, errate e omesse', () => {
  const { BL, plain } = loadCore();
  const items = [
    { answer: 0, correct: true }, { answer: 1, correct: false },
    { answer: null, correct: false }, { answer: 2, correct: true }];
  const r = plain(BL.scoreItems(items));
  assert.deepEqual([r.C, r.E, r.O, r.N], [2, 1, 1, 4]);
  assert.equal(r.raw, 1.25);
});

test('formattazioni: fmt1, pct, fmtDur', () => {
  const { BL } = loadCore();
  assert.equal(BL.fmt1(9.375), '9,4');
  assert.equal(BL.fmt1(30), '30,0');
  assert.equal(BL.pct(0.756), '76%');
  assert.equal(BL.fmtDur(75), '1:15');
  assert.equal(BL.fmtDur(-5), '0:00');
});

test('date: addDays, iso, isDue, isSoon con orologio controllato', () => {
  const { BL } = loadCore();
  assert.equal(BL.todayISO(), '2026-10-27');
  assert.equal(BL.addDays('2026-10-27', 5), '2026-11-01');
  assert.equal(BL.addDays('2026-03-01', -1), '2026-02-28');
  assert.equal(BL.iso(T0 + DAY), '2026-10-28');
  assert.equal(BL.isDue({ nextReview: '2026-10-26' }), true);
  assert.equal(BL.isDue({ nextReview: '2026-10-27' }), false);
  assert.equal(BL.isDue(null), false);
  assert.equal(BL.isSoon({ nextReview: '2026-11-26' }), true);
  assert.equal(BL.isSoon({ nextReview: '2026-11-27' }), false);
  assert.equal(BL.isSoon({ nextReview: '2026-10-26' }), false);
});

test('rng e shuffle: deterministici, permutazione, non modificano l\'originale', () => {
  const { BL, plain } = loadCore();
  const a = BL.rng(42), b = BL.rng(42);
  const seqA = [a(), a(), a()], seqB = [b(), b(), b()];
  assert.deepEqual(seqA, seqB);
  seqA.forEach(x => assert.ok(x >= 0 && x < 1));
  const orig = [1, 2, 3, 4, 5, 6, 7, 8];
  const s = plain(BL.shuffle(orig, BL.rng(7)));
  assert.deepEqual(orig, [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.deepEqual([...s].sort((x, y) => x - y), orig);
  assert.deepEqual(plain(BL.shuffle(orig, BL.rng(7))), s);
});

test('livelli e XP: 150 XP per livello', () => {
  const { BL, plain } = loadCore();
  assert.deepEqual(plain(BL.level(0)), { level: 1, into: 0, need: 150, pct: 0 });
  assert.equal(BL.level(150).level, 2);
  assert.equal(BL.level(299).level, 2);
  assert.equal(BL.level(300).level, 3);
  assert.equal(BL.xp({ xpLog: [{ amount: 10 }, { amount: 0 }, { amount: 5 }] }), 15);
});
