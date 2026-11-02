const test = require('node:test');
const assert = require('node:assert');
const { cartTotal, itemCount } = require('../src/cart');

const items = [{ price: 500, qty: 2 }, { price: 250, qty: 3 }];

test('total without code', () => assert.strictEqual(cartTotal(items), 1750));
test('total with TEN', () => assert.strictEqual(cartTotal(items, 'TEN'), 1575));
test('item count sums quantities', () => assert.strictEqual(itemCount(items), 5));
