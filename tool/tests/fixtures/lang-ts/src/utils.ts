// #f:tx.ns.format@operation

export namespace Formatter {
  // #f:tx.ns.format

  export function formatDate(d: Date): string {
    return d.toISOString();
  }

  // #f:tx.ns.format

  export function formatAmount(n: number): string {
    return n.toFixed(2);
  }
}

// #f:tx.core.validate

/** Comment with inline block. */
export function checkLength(s: string /* max: 100 */, limit: number): boolean {
  return s.length <= limit;
}

// #f:tx.core.validate

export function defaultMessage(): string {
  const prefix = "// validation";
  return prefix + " failed";
}
