import { describe, expect, it } from 'vitest';

import { cn } from './utils';

describe('cn', () => {
  it('joins plain class names', () => {
    expect(cn('alpha', 'beta')).toBe('alpha beta');
  });
});
