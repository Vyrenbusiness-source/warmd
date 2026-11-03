import { describe, it, expect } from 'vitest';
import { formatPrice, Price } from '../src/components/price.js';

describe('formatPrice', () => {
  it('whole and cents', () => expect(formatPrice(1250)).toBe('12.50'));
  it('single digit cents', () => expect(formatPrice(1205)).toBe('12.05'));
  it('negative', () => expect(formatPrice(-399)).toBe('-3.99'));
  it('element', () => expect(Price(799).textContent).toBe('7.99'));
});
