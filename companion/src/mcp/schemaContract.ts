import { z } from "zod";

// Shared by the plan descriptions and ledger-apply --schema. This renders
// structural input types only; refinements need their own prose contract.
type JsonSchema = z.core.JSONSchema.JSONSchema;

function fieldType(schema: JsonSchema | boolean): string {
  if (typeof schema === "boolean") return schema ? "unknown (any JSON value)" : "never";
  let type: string;
  if (schema.const !== undefined) type = JSON.stringify(schema.const);
  else if (schema.enum) type = schema.enum.map((value) => JSON.stringify(value)).join("|");
  else if (schema.anyOf || schema.oneOf) type = `(${(schema.anyOf ?? schema.oneOf)!.map(fieldType).join(" or ")})`;
  else if (schema.type === "array") {
    type = `[${fieldType((schema.items ?? {}) as JsonSchema)}]`;
  } else if (schema.type === "object") {
    const required = schema.required ?? [];
    const fields = Object.entries(schema.properties ?? {}).map(([key, value]) =>
      `${key}${required.includes(key) ? "" : "?"}: ${fieldType(value)}`);
    if (schema.additionalProperties !== false) {
      fields.push(`[key: ${fieldType(schema.propertyNames ?? { type: "string" })}]: ${fieldType(
        typeof schema.additionalProperties === "object" ? schema.additionalProperties : {})}`);
    }
    type = `{${fields.join(", ")}}${schema.additionalProperties === false ? " (strict)" : ""}`;
  } else type = Array.isArray(schema.type) ? schema.type.join("|") : schema.type ?? "unknown (any JSON value)";

  const constraints: string[] = [];
  for (const [key, label] of [
    ["minimum", ">="], ["maximum", "<="], ["exclusiveMinimum", ">"], ["exclusiveMaximum", "<"],
    ["multipleOf", "multiple of "], ["minLength", "length >="], ["maxLength", "length <="],
    ["minItems", "items >="], ["maxItems", "items <="],
    ["minProperties", "keys >="], ["maxProperties", "keys <="],
  ] as const) {
    if (schema[key] !== undefined) constraints.push(`${label}${schema[key]}`);
  }
  if (schema.pattern !== undefined) constraints.push(`matching ${schema.pattern}`);
  if (schema.format !== undefined) constraints.push(`format ${schema.format}`);
  if (schema.uniqueItems) constraints.push("unique items");
  if (constraints.length) type += ` (${constraints.join(", ")})`;
  if (schema.default !== undefined) type += ` default ${JSON.stringify(schema.default)}`;
  return type;
}

/** Required fields | optional fields of an input object, with no depth cutoff. */
export function fieldLine(schema: z.ZodType, skip: string[] = []): string {
  const json = z.toJSONSchema(schema, { io: "input", unrepresentable: "any" });
  const required = json.required ?? [];
  const fields = Object.entries(json.properties ?? {}).filter(([key]) => !skip.includes(key));
  const list = (want: boolean) => fields.filter(([key]) => required.includes(key) === want)
    .map(([key, value]) => `${key}: ${fieldType(value)}`).join("; ");
  return `${list(true) || "-"} | optional: ${list(false) || "-"}`;
}

export function stepLines(options: readonly z.ZodObject<{ action: z.ZodLiteral<string> }>[]): string[] {
  return options.map((option) => `  ${option.shape.action.value}: ${fieldLine(option, ["action"])}`);
}
