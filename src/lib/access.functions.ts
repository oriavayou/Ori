import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

type Role = "admin" | "customer" | "none";

async function resolveRole(ctx: { supabase: any; userId: string; claims: any }): Promise<Role> {
  const { data: roles } = await ctx.supabase.from("user_roles").select("role").eq("user_id", ctx.userId);
  const list = (roles ?? []).map((r: { role: string }) => r.role);
  if (list.includes("admin")) return "admin";
  if (list.includes("customer")) return "customer";
  return "none";
}

async function assertAdmin(ctx: any) {
  if ((await resolveRole(ctx)) !== "admin") throw new Error("אין הרשאה");
}

export const getAccess = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }) => {
    const role = await resolveRole(context);
    let used = false;
    if (role === "customer") {
      const { data } = await context.supabase
        .from("customer_accounts")
        .select("report_used_at")
        .eq("user_id", context.userId)
        .maybeSingle();
      used = !!data?.report_used_at;
    }
    const allowed = role === "admin" || (role === "customer" && !used);
    let html: string | null = null;
    if (allowed) {
      const { SITE_HTML } = await import("@/site/site.server");
      html = SITE_HTML;
    }
    return { role, used, html };
  });

export const consumeReport = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }) => {
    const role = await resolveRole(context);
    if (role === "admin") return { ok: true };
    if (role !== "customer") throw new Error("אין הרשאה");
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data } = await supabaseAdmin
      .from("customer_accounts")
      .update({ report_used_at: new Date().toISOString() })
      .eq("user_id", context.userId)
      .is("report_used_at", null)
      .select("user_id");
    if (!data || data.length === 0) throw new Error("הדוח בחשבון זה כבר הופק");
    return { ok: true };
  });

export const listCustomers = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }) => {
    await assertAdmin(context);
    const { data, error } = await context.supabase
      .from("customer_accounts")
      .select("*")
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);
    return data ?? [];
  });

export const createCustomer = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d) =>
    z
      .object({
        email: z.string().trim().email().max(255),
        password: z.string().min(8).max(72),
        note: z.string().trim().max(200).optional(),
      })
      .parse(d),
  )
  .handler(async ({ context, data }) => {
    await assertAdmin(context);
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data: created, error } = await supabaseAdmin.auth.admin.createUser({
      email: data.email,
      password: data.password,
      email_confirm: true,
    });
    if (error || !created.user) throw new Error(error?.message ?? "יצירת המשתמש נכשלה");
    const id = created.user.id;
    await supabaseAdmin.from("user_roles").insert({ user_id: id, role: "customer" });
    await supabaseAdmin
      .from("customer_accounts")
      .insert({ user_id: id, email: data.email.toLowerCase(), note: data.note || null });
    return { ok: true };
  });

export const reopenCustomer = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d) => z.object({ userId: z.string().uuid() }).parse(d))
  .handler(async ({ context, data }) => {
    await assertAdmin(context);
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    await supabaseAdmin.from("customer_accounts").update({ report_used_at: null }).eq("user_id", data.userId);
    return { ok: true };
  });

export const deleteCustomer = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d) => z.object({ userId: z.string().uuid() }).parse(d))
  .handler(async ({ context, data }) => {
    await assertAdmin(context);
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data: isCustomer } = await supabaseAdmin
      .from("customer_accounts")
      .select("user_id")
      .eq("user_id", data.userId)
      .maybeSingle();
    if (!isCustomer) throw new Error("לא נמצא לקוח");
    await supabaseAdmin.from("customer_accounts").delete().eq("user_id", data.userId);
    await supabaseAdmin.from("user_roles").delete().eq("user_id", data.userId);
    await supabaseAdmin.auth.admin.deleteUser(data.userId);
    return { ok: true };
  });

export const getPublicSite = createServerFn({ method: "GET" }).handler(async () => {
  const { SITE_HTML } = await import("@/site/site.server");
  return { html: SITE_HTML };
});
