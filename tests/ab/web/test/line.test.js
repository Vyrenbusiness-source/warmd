import { it, expect } from 'vitest';
import { Line, lineTotal } from '../src/components/line.js';

it('line total', () => expect(lineTotal({ price: 250, qty: 3 })).toBe(750));
it('line text', () => expect(Line({ name: 'Tea', price: 120, qty: 2 }).textContent).toBe('2 x Tea 2.40'));
