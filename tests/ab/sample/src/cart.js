// Shopping cart totals. Prices are in cents.
function lineTotal(item) {
  return item.price * item.qty;
}

function discount(total, code) {
  if (code === 'TEN') return Math.round(total * 0.9);
  if (code === 'HALF') return Math.round(total / 2);
  return total;
}

function cartTotal(items, code) {
  const sum = items.reduce((acc, it) => acc + lineTotal(it), 0);
  return discount(sum, code);
}

function itemCount(items) {
  return items.reduce((acc, it) => acc + it.qty, 0);
}

module.exports = { lineTotal, discount, cartTotal, itemCount };
