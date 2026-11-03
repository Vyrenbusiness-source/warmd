// Small count bubble, hidden at zero, capped at 99+.
export function Badge(count) {
  const el = document.createElement('span');
  el.className = 'badge';
  el.hidden = count <= 0;
  el.textContent = count > 99 ? '99+' : String(count);
  return el;
}
