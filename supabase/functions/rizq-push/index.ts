import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-rizq-webhook-secret", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const publicKey = Deno.env.get("VAPID_PUBLIC_KEY")!;
  const privateKey = Deno.env.get("VAPID_PRIVATE_KEY")!;
  const subject = Deno.env.get("VAPID_SUBJECT") || "mailto:admin@rizq.example";
  const webhookSecret = Deno.env.get("RIZQ_WEBHOOK_SECRET")!;
  const admin = createClient(url, serviceKey);
  webpush.setVapidDetails(subject, publicKey, privateKey);

  const incomingSecret = req.headers.get("x-rizq-webhook-secret");
  if (incomingSecret && incomingSecret === webhookSecret) {
    const payload = await req.json().catch(() => ({}));
    const table = payload.table || payload.record?.table || "";
    const event = payload.type || "INSERT";
    if (event !== "INSERT" || !["support_messages", "deposit_requests", "withdrawal_requests"].includes(table)) return json({ ok: true, skipped: true });
    const labels: Record<string, string> = {
      support_messages: "رسالة جديدة من عميل",
      deposit_requests: "طلب إيداع جديد",
      withdrawal_requests: "طلب سحب جديد"
    };
    if (table === "support_messages" && (payload.record?.sender_role || payload.record?.sender) === "admin") return json({ ok: true, skipped: true });
    if (table !== "support_messages" && payload.record?.status && payload.record.status !== "pending") return json({ ok: true, skipped: true });
    const { data: rows, error } = await admin.from("rizq_push_subscriptions").select("endpoint,subscription");
    if (error) return json({ error: error.message }, 500);
    const message = { title: "تنبيه RIZQ", body: labels[table], url: "/", tag: table + "-" + Date.now() };
    const expired: string[] = [];
    await Promise.all((rows || []).map(async (row) => {
      try { await webpush.sendNotification(row.subscription, JSON.stringify(message)); }
      catch (e) { if (e?.statusCode === 404 || e?.statusCode === 410) expired.push(row.endpoint); else console.error("Push delivery failed", e?.statusCode || e); }
    }));
    if (expired.length) await admin.from("rizq_push_subscriptions").delete().in("endpoint", expired);
    return json({ ok: true, sent: (rows || []).length - expired.length, expired: expired.length });
  }

  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Unauthorized" }, 401);
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: "Bearer " + token } } });
  const { data: userData, error: userError } = await userClient.auth.getUser(token);
  if (userError || !userData.user || userData.user.app_metadata?.role !== "admin") return json({ error: "Admin only" }, 403);

  const body = await req.json().catch(() => ({}));
  if (body.action === "subscribe" && body.subscription?.endpoint) {
    const { error } = await admin.from("rizq_push_subscriptions").upsert({
      endpoint: body.subscription.endpoint, user_id: userData.user.id, subscription: body.subscription, updated_at: new Date().toISOString()
    });
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true });
  }
  if (body.action === "unsubscribe" && body.endpoint) {
    const { error } = await admin.from("rizq_push_subscriptions").delete().eq("endpoint", body.endpoint).eq("user_id", userData.user.id);
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true });
  }
  return json({ error: "Invalid action" }, 400);
});