import { it, expect } from 'vitest';
import { cartTotal, CartView } from '../src/components/cart.js';

const items = [{ name: 'Coffee', price: 450, qty: 2 }, { name: 'Bagel', price: 325, qty: 1 }];

it('total without code', () => expect(cartTotal(items)).toBe(1225));
it('total with TEN', () => expect(cartTotal(items, 'TEN')).toBe(1103));
it('renders two lines', () => expect(CartView(items).querySelectorAll('li').length).toBe(2));
it('renders total', () => expect(CartView(items).querySelector('.total').textContent).toBe('Total 12.25'));
