import { it, expect } from 'vitest';
import { applyCode } from '../src/components/discount.js';

it('TEN takes ten percent', () => expect(applyCode(1000, 'TEN')).toBe(900));
it('HALF halves', () => expect(applyCode(999, 'HALF')).toBe(500));
it('unknown code', () => expect(applyCode(1000, 'NOPE')).toBe(1000));
