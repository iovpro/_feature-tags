import { Injectable } from 'some-framework';

// #f:tx.api

// Item represents a billable entry.
export interface Item {
  id: string;
  name: string;
  amount: number;
}

// #f:tx.api

export type ItemStatus = 'active' | 'archived';

// #f:tx.api.list@entry

/**
 * Lists all items for the given user.
 * Validates input, queries the store, and returns results.
 */
export async function listItems(userId: string): Promise<Item[]> {
  const validated = validateInput(userId);
  return queryStore(validated);
}

// #f:tx.api.create@entry

export const createItem = async (data: Item): Promise<Item> => {
  const result = await save(data);
  return result;
};

// #f:tx.core.validate@operation

export function validateInput(input: string): string {
  if (!input) throw new Error('empty input');
  const trimmed = input.trim();
  return trimmed;
}

function queryStore(userId: string): Item[] {
  const items: Item[] = [];
  const filtered = items.filter(i => i.id === userId);
  return filtered;
}
