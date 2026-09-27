import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';

test('customer confirmation renders final price and booking details without internal tariff label', () => {
  const source = readFileSync(new URL('./BookingForm.tsx', import.meta.url), 'utf8');
  const block = source.slice(source.indexOf('{confirmationData && ('), source.indexOf('\n      <form'));
  const jsx = block.slice(block.indexOf('(') + 1, block.lastIndexOf(')}'));
  const code = ts.transpileModule(`const view = (${jsx});`, {
    compilerOptions: { jsx: ts.JsxEmit.React, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const data = { date: '2026-10-15', startTime: '10:00', endTime: '11:00',
    familyName: 'Oś testowa', mode: 'position', positionName: 'Stanowisko 2',
    shootersCount: 2, durationMinutes: 60, pricingDayGroup: 'mon_thu',
    totalPrice: 123, currencyCode: 'PLN' };
  const view = Function('React', 'confirmationData', 'formatReservationDate', 'formatDuration',
    'formatMoney', 'BOOKING_DAY_GROUP_LABELS', 'message', code + '\nreturn view;')(
    React, data, value => value, value => `${value} min`, (value, currency) => `${value} ${currency}`,
    { mon_thu: 'Poniedziałek–czwartek' }, 'Potwierdzono');
  const html = renderToStaticMarkup(view);
  assert.doesNotMatch(html, /Poniedziałek–czwartek|mon_thu/);
  for (const value of ['123 PLN', '2026-10-15', '10:00', '11:00', 'Oś testowa',
    'Pojedyncze stanowisko', 'Stanowisko 2', '2 strzelców', '60 min']) assert.ok(html.includes(value), value);
});
