export const toolPayloads = {
  target: (value: { x: number; y: number }) => ({ target: value }),
  mine: ({ x, y, count }: { x: number; y: number; count?: number }) => ({ target: { x, y }, count }),
  place: ({ x, y, name, direction }: { x: number; y: number; name: string; direction?: number }) => ({ item: name, position: { x, y }, direction }),
  insert: ({ x, y, items: values }: { x: number; y: number; items: Record<string, number> }) => ({ target: { x, y }, items: values }),
  extract: ({ x, y, items: values }: { x: number; y: number; items?: Record<string, number> }) => values === undefined ? ({ target: { x, y }, all: true }) : ({ target: { x, y }, items: values }),
  recipe: ({ x, y, recipe }: { x: number; y: number; recipe: string }) => ({ target: { x, y }, recipe }),
  rotate: ({ x, y, direction }: { x: number; y: number; direction?: number }) => ({ target: { x, y }, direction }),
  inspect: (positions: Array<{ x: number; y: number }>) => ({ targets: positions }),
  placement: ({ x, y, name, direction }: { x: number; y: number; name: string; direction?: number }) => ({ item: name, position: { x, y }, direction }),
  canPlace: (placements: Array<{ x: number; y: number; name: string; direction?: number }>) => ({ placements: placements.map((placement) => toolPayloads.placement(placement)) }),
  buildPlan: (steps: Array<{ x: number; y: number; name: string; [key: string]: unknown }>, rest: Record<string, unknown>) => ({ ...rest, steps: steps.map(({ x, y, name, ...step }) => ({ ...step, item: name, position: { x, y } })) }),
};
