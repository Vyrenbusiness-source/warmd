import { Line, lineTotal } from './line.js';
import { Price } from './price.js';
import { applyCode } from './discount.js';

export function cartTotal(items, code) {
  return applyCode(items.reduce((sum, it) => sum + lineTotal(it), 0), code);
}

export function CartView(items, code) {
  const root = document.createElement('section');
  root.className = 'cart';
  const list = document.createElement('ul');
  items.forEach((it) => list.append(Line(it)));
  const total = document.createElement('p');
  total.className = 'total';
  total.append('Total ', Price(cartTotal(items, code)));
  root.append(list, total);
  return root;
}
