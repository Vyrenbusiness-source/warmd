import { CartView } from './components/cart.js';
import { Header } from './components/header.js';

const items = [
  { name: 'Coffee', price: 450, qty: 2 },
  { name: 'Bagel', price: 325, qty: 1 },
];
document.querySelector('#app').append(Header('Shop'), CartView(items, 'TEN'));
