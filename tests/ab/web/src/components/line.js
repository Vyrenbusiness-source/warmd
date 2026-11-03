import { Price } from './price.js';

export function lineTotal(item) {
  return item.price * item.qty;
}

export function Line(item) {
  const li = document.createElement('li');
  li.className = 'line';
  li.append(`${item.qty} x ${item.name} `, Price(lineTotal(item)));
  return li;
}
