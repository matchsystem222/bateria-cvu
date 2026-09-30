import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { failureReasons, personName } from "../_shared/verdict.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Método no permitido", { status: 405 });
  const secret = Deno.env.get("DIDIT_WEBHOOK_SECRET") ?? "";
  const diditKey = Deno.env.get("DIDIT_API_KEY") ?? "";
  if (!secret) return new Response("Falta el secreto del webhook", { status: 503 });

  const raw = await req.text();
  let body: Record<string, unknown>;
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return new Response("JSON inválido", { status: 400 });
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return new Response("JSON inválido", { status: 400 });
  }
  const timestamp = req.headers.get("x-timestamp") ?? "";
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - Number(timestamp)) > 300) return new Response("Timestamp vencido", { status: 401 });

  const v2 = req.headers.get("x-signature-v2");
  const simple = req.headers.get("x-signature-simple");
  const rawSig = req.headers.get("x-signature");
  const trustedBody = v2 ? await hmacHex(secret, canonical(body)) === v2 : false;
  const trustedRaw = !trustedBody && rawSig ? await hmacHex(secret, raw) === rawSig : false;
  const trustedSimple = !trustedBody && !trustedRaw && simple
    ? await hmacHex(secret, [body.timestamp ?? "", body.session_id ?? "", body.status ?? "", body.webhook_type ?? ""].join(":")) === simple
    : false;
  if (!trustedBody && !trustedRaw && !trustedSimple) return new Response("Firma inválida", { status: 401 });

  const sessionId = String(body.session_id ?? "");
  const caseId = String(body.vendor_data ?? "");
  const status = String(body.status ?? "");
  if (!sessionId || !caseId || !status) return new Response("Falta la entrevista", { status: 400 });

  let decision = body.decision ?? null;
  if (!trustedBody && !trustedRaw) {
    if (!diditKey) return new Response("Firma incompleta", { status: 401 });
    const fresh = await fetch(`https://verification.didit.me/v3/session/${sessionId}/decision/`, {
      headers: { "x-api-key": diditKey },
    });
    if (!fresh.ok) return new Response("No se pudo confirmar el expediente", { status: 401 });
    const fetched = await fresh.json();
    decision = fetched?.id_verifications ? fetched : fetched?.decision ?? fetched;
  }

  const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  const { data: existing } = await admin.from("onboarding_cases").select("id, first_name, last_name, confirmed_at").eq("id", caseId).maybeSingle();
  if (!existing) return new Response("Caso desconocido", { status: 404 });

  const names = personName(decision);
  const reasons = failureReasons(decision, status);
  const alreadyConfirmed = Boolean(existing.confirmed_at);
  const stillConfirmed = alreadyConfirmed && status === "Approved";
  const { data: priorDossier, error: priorError } = await admin
    .from("kyc_dossiers")
    .select("corrected")
    .eq("case_id", caseId)
    .not("corrected", "is", null)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (priorError) return new Response("No se leyó la corrección", { status: 500 });
  const dossier: Record<string, unknown> = {
    session_id: sessionId,
    case_id: caseId,
    payload: decision ?? { status, session_id: sessionId },
    updated_at: new Date().toISOString(),
  };
  if (priorDossier?.corrected) dossier.corrected = priorDossier.corrected;
  const { error: dossierError } = await admin.from("kyc_dossiers").upsert(dossier);
  if (dossierError) return new Response("No se guardó el expediente", { status: 500 });

  const { error: caseError } = await admin.from("onboarding_cases").update({
    first_name: alreadyConfirmed ? existing.first_name : (names.first_name ?? existing.first_name),
    last_name: alreadyConfirmed ? existing.last_name : (names.last_name ?? existing.last_name),
    didit_status: status,
    apt_for_cvu: stillConfirmed,
    confirmed_at: stillConfirmed ? existing.confirmed_at : null,
    failure_reasons: reasons,
  }).eq("id", caseId);
  if (caseError) return new Response("No se actualizó el caso", { status: 500 });
  return new Response("ok", { status: 200 });
});

function canonical(value: unknown): string {
  return JSON.stringify(sortKeys(shortenFloats(value)));
}

function shortenFloats(data: unknown): unknown {
  if (Array.isArray(data)) return data.map(shortenFloats);
  if (data !== null && typeof data === "object") {
    return Object.fromEntries(Object.entries(data as Record<string, unknown>).map(([key, item]) => [key, shortenFloats(item)]));
  }
  if (typeof data === "number" && !Number.isInteger(data) && data % 1 === 0) return Math.trunc(data);
  return data;
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value !== null && typeof value === "object") {
    return Object.keys(value as Record<string, unknown>).sort().reduce<Record<string, unknown>>((acc, key) => {
      acc[key] = sortKeys((value as Record<string, unknown>)[key]);
      return acc;
    }, {});
  }
  return value;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
