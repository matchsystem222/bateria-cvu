import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const header = req.headers.get("Authorization") ?? "";
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: header } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return json({ error: "Tenés que entrar como admin" }, 401);

  const admin = createClient(supabaseUrl, serviceKey);
  const { data: adminRow } = await admin.from("admins").select("user_id").eq("user_id", userData.user.id).maybeSingle();
  if (!adminRow) return json({ error: "Solo el admin puede dar de alta promotores" }, 403);

  const body = await req.json().catch(() => ({}));
  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || password.length < 8) {
    return json({ error: "Hace falta un correo y una contraseña de al menos 8 caracteres" }, 400);
  }

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (createError || !created.user) return json({ error: createError?.message ?? "No se creó el acceso" }, 400);

  const { error: insertError } = await admin.from("promoters").insert({ user_id: created.user.id, email });
  if (insertError) return json({ error: "El acceso se creó pero no quedó como promotor" }, 500);
  return json({ email });
});
