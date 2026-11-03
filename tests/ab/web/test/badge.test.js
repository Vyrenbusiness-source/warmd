import { it, expect } from 'vitest';
import { Badge } from '../src/components/badge.js';

it('hidden at zero', () => expect(Badge(0).hidden).toBe(true));
it('shows count', () => expect(Badge(7).textContent).toBe('7'));
it('caps at 99+', () => expect(Badge(150).textContent).toBe('99+'));
