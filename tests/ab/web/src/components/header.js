export function Header(title) {
  const h = document.createElement('header');
  const h1 = document.createElement('h1');
  h1.textContent = title;
  h.append(h1);
  return h;
}
