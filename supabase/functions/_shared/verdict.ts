const CAPTURE_REASONS: Record<string, string> = {
  IMAGE_TOO_BLURRY: "La foto del documento está borrosa",
  IMAGE_TOO_DARK: "La foto del documento está oscura",
  IMAGE_TOO_BRIGHT: "La foto del documento está muy clara",
  DOCUMENT_NOT_FULLY_VISIBLE: "El documento no se ve completo",
  LOW_FACE_QUALITY: "La cámara de la cara no se ve nítida",
  LOW_FACE_LUMINANCE: "La cara se ve muy oscura",
  NO_FACE_DETECTED: "No se detectó la cara",
  LOW_LIVENESS_SCORE: "La prueba de vida no alcanzó",
  LOW_FACE_MATCH_SIMILARITY: "La cara no coincide con el documento",
};

const GENERIC = "No pasó la verificación";

export function personName(decision: unknown): { first_name: string | null; last_name: string | null } {
  const checks = Array.isArray((decision as { id_verifications?: unknown })?.id_verifications)
    ? (decision as { id_verifications: Array<Record<string, unknown>> }).id_verifications
    : [];
  const check = checks.find((item) => typeof item?.first_name === "string" || typeof item?.last_name === "string");
  return {
    first_name: cleanName(check?.first_name),
    last_name: cleanName(check?.last_name),
  };
}

export function failureReasons(decision: unknown, status: string): string[] {
  if (status === "Approved" || status === "Not Started" || status === "In Progress") return [];
  const reasons = new Set<string>();
  for (const code of riskCodes(decision)) {
    const known = CAPTURE_REASONS[code];
    if (known) reasons.add(known);
  }
  if (reasons.size === 0 && (status === "Declined" || status === "Resubmitted" || status === "In Review")) {
    reasons.add(GENERIC);
  }
  return [...reasons];
}

export function aptForCvu(status: string): boolean {
  return status === "Approved";
}

function cleanName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const name = value.replace(/\s+/g, " ").trim();
  if (!name || name.length > 80) return null;
  return name;
}

function riskCodes(decision: unknown): string[] {
  const codes: string[] = [];
  walk(decision, codes);
  return codes;
}

function walk(node: unknown, codes: string[]): void {
  if (!node || typeof node !== "object") return;
  if (Array.isArray(node)) {
    for (const item of node) walk(item, codes);
    return;
  }
  const record = node as Record<string, unknown>;
  if (typeof record.risk === "string") codes.push(record.risk);
  for (const value of Object.values(record)) {
    if (value && typeof value === "object") walk(value, codes);
  }
}
