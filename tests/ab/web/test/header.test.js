import { it, expect } from 'vitest';
import { Header } from '../src/components/header.js';

it('title', () => expect(Header('Shop').querySelector('h1').textContent).toBe('Shop'));
