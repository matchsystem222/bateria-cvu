import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { json, preflight } from "../_shared/http.ts";

const RETRY = new Set(["Declined", "Resubmitted", "Abandoned", "Expired", "Kyc Expired", "Not Started"]);

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const diditKey = Deno.env.get("DIDIT_API_KEY") ?? "";
  const workflowId = Deno.env.get("DIDIT_WORKFLOW_ID") ?? "";
  const callbackBase = Deno.env.get("PUBLIC_PROMOTER_URL") ?? "https://matchsystem222.github.io/bateria-cvu/promotor/";
  if (!diditKey || !workflowId) return json({ error: "Falta la clave de Didit en el servidor" }, 503);

  const header = req.headers.get("Authorization") ?? "";
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: header } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return json({ error: "Tenés que entrar como promotor" }, 401);

  const admin = createClient(supabaseUrl, serviceKey);
  const { data: promoter } = await admin.from("promoters").select("user_id").eq("user_id", userData.user.id).maybeSingle();
  if (!promoter) return json({ error: "Esta cuenta no es de un promotor" }, 403);

  const body = await req.json().catch(() => ({}));
  const requested = typeof body.case_id === "string" ? body.case_id : "";
  let caseId = requested;

  if (caseId) {
    const { data: existing } = await admin.from("onboarding_cases").select("id, promoter_id, didit_status").eq("id", caseId).maybeSingle();
    if (!existing || existing.promoter_id !== userData.user.id) return json({ error: "Esa entrevista no es tuya" }, 404);
    if (!RETRY.has(existing.didit_status)) return json({ error: "Esta entrevista no se puede reintentar" }, 409);
  } else {
    const { data: created, error } = await admin.from("onboarding_cases").insert({ promoter_id: userData.user.id }).select("id").single();
    if (error || !created) return json({ error: "No se pudo abrir la entrevista" }, 500);
    caseId = created.id;
  }

  const callback = new URL(callbackBase);
  callback.searchParams.set("case", caseId);
  const didit = await fetch("https://verification.didit.me/v3/session/", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": diditKey },
    body: JSON.stringify({ workflow_id: workflowId, vendor_data: caseId, callback: callback.toString() }),
  });
  const payload = await didit.json().catch(() => ({}));
  if (!didit.ok || typeof payload.url !== "string") {
    return json({ error: "Didit no abrió la verificación", case_id: caseId }, 502);
  }

  await admin.from("onboarding_cases").update({ didit_status: payload.status || "Not Started", apt_for_cvu: false, failure_reasons: [] }).eq("id", caseId);
  return json({ case_id: caseId, url: payload.url, status: payload.status || "Not Started" });
});
