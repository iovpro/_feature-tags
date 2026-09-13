import { listItems, validateInput } from './service';

describe('ItemService', () => {
  // #f:tx.api.list

  it('lists items for a valid user', async () => {
    const items = await listItems('user-1');
    expect(items).toBeDefined();
  });

  // #f:tx.api.list #f:tx.core.validate

  it('rejects empty user id', async () => {
    await expect(listItems('')).rejects.toThrow('empty input');
  });

  // #f:tx.core.validate

  test('validates trimming', () => {
    expect(validateInput('  hello  ')).toBe('hello');
  });
});
