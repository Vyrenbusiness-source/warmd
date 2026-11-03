// Prices are integer cents. Shows them as 12.05 style text.
export function formatPrice(cents) {
  const sign = cents < 0 ? '-' : '';
  const abs = Math.abs(cents);
  const euros = Math.floor(abs / 100);
  const rest = abs % 100;
  return `${sign}${euros}.${rest}`;
}

export function Price(cents) {
  const el = document.createElement('span');
  el.className = 'price';
  el.textContent = formatPrice(cents);
  return el;
}
