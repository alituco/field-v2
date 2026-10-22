const PAGE_SIZE = 500;
const ID_BATCH_SIZE = 50;
const ID_BATCH_CONCURRENCY = 4;

type RowResult<T> = { data: T[] | null; error: unknown };

/** Each query must include a stable, unique final order before applying range. */
export async function loadAllRows<T>(
  page: (from: number, to: number) => PromiseLike<RowResult<T>>,
): Promise<T[]> {
  const loaded: T[] = [];
  for (let from = 0; ; from += PAGE_SIZE) {
    const { data, error } = await page(from, from + PAGE_SIZE - 1);
    if (error) throw error;
    loaded.push(...(data ?? []));
    if ((data ?? []).length < PAGE_SIZE) return loaded;
  }
}

/** Bound both REST URL length and response size for multi-match hydration. */
export async function loadRowsForIds<T>(
  ids: string[],
  page: (ids: string[], from: number, to: number) => PromiseLike<RowResult<T>>,
): Promise<T[]> {
  const uniqueIds = [...new Set(ids)];
  const batches: string[][] = [];
  for (let index = 0; index < uniqueIds.length; index += ID_BATCH_SIZE) {
    batches.push(uniqueIds.slice(index, index + ID_BATCH_SIZE));
  }
  const loaded: T[] = [];
  for (let offset = 0; offset < batches.length; offset += ID_BATCH_CONCURRENCY) {
    const results = await Promise.all(batches.slice(offset, offset + ID_BATCH_CONCURRENCY)
      .map((batch) => loadAllRows((from, to) => page(batch, from, to))));
    for (const result of results) loaded.push(...result);
  }
  return loaded;
}
