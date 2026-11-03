// Discount codes. Unknown codes change nothing.
const CODES = { TEN: 0.9, HALF: 0.5 };

export function applyCode(total, code) {
  const factor = CODES[code];
  return factor ? Math.round(total * factor) : total;
}
