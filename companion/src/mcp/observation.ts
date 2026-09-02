export function normalizeObservation(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("observe_local returned an invalid object");
  const observation = value as Record<string, unknown>;
  const arrayField = (name: "entities" | "resource_patches") => {
    const field = observation[name];
    if (Array.isArray(field)) return field;
    if (field && typeof field === "object" && Object.keys(field as Record<string, unknown>).length === 0) return [];
    throw new Error(`observe_local returned invalid ${name}`);
  };
  return { ...observation, entities: arrayField("entities"), resource_patches: arrayField("resource_patches") };
}
