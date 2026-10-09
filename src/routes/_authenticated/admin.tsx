import { createFileRoute, Navigate, redirect } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useState } from "react";
import { getAccess, listCustomers, createCustomer, reopenCustomer, deleteCustomer } from "@/lib/access.functions";
import { SiteBar } from "@/components/SiteBar";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { CheckCircle2, KeyRound, Plus, RotateCcw, Trash2, Users } from "lucide-react";

export const Route = createFileRoute("/_authenticated/admin")({
  beforeLoad: async () => {
    const access = await getAccess();
    if (access.role !== "admin") throw redirect({ to: "/app", replace: true });
  },
  head: () => ({
    meta: [
      { title: "ניהול לקוחות — מאזן" },
      { name: "description", content: "יצירת משתמשים ללקוחות משלמים." },
      { property: "og:title", content: "ניהול לקוחות — מאזן" },
      { property: "og:description", content: "יצירת משתמשים ללקוחות משלמים." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: AdminPage,
});

function AdminPage() {
  const { user } = Route.useRouteContext();
  const qc = useQueryClient();
  const fetchAccess = useServerFn(getAccess);
  const fetchList = useServerFn(listCustomers);
  const create = useServerFn(createCustomer);
  const reopen = useServerFn(reopenCustomer);
  const remove = useServerFn(deleteCustomer);

  const access = useQuery({ queryKey: ["access"], queryFn: () => fetchAccess(), staleTime: Infinity });
  const isAdmin = access.data?.role === "admin";
  const list = useQuery({ queryKey: ["customers"], queryFn: () => fetchList(), enabled: isAdmin });

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  if (access.isLoading) return <div className="p-8 text-center">טוען…</div>;
  if (!isAdmin) return <Navigate to="/app" />;

  async function run(fn: () => Promise<unknown>, ok?: string) {
    setBusy(true);
    setMsg(null);
    try {
      await fn();
      if (ok) setMsg(ok);
      await qc.invalidateQueries({ queryKey: ["customers"] });
    } catch (e) {
      setMsg((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  function genPassword() {
    const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
    const arr = new Uint32Array(10);
    crypto.getRandomValues(arr);
    setPassword(Array.from(arr, (n) => chars[n % chars.length]).join(""));
  }

  return (
    <div className="min-h-screen bg-background">
      <SiteBar email={user.email} isAdmin />
      <main className="mx-auto max-w-5xl space-y-8 p-5 sm:p-8">
        <header className="flex items-end justify-between gap-4 border-b border-border pb-6">
          <div><p className="text-xs font-bold text-gold">סביבת ניהול</p><h1 className="mt-1 text-3xl font-bold">ניהול לקוחות</h1></div>
          <span className="grid size-11 place-items-center rounded-md bg-secondary text-primary"><Users className="size-5" /></span>
        </header>
        <section className="space-y-5 rounded-lg border border-border bg-card p-6 shadow-lg shadow-primary/5">
          <div className="flex items-center gap-3"><span className="grid size-9 place-items-center rounded-md bg-primary text-primary-foreground"><Plus className="size-4" /></span><h2 className="text-xl font-bold">לקוח חדש</h2></div>
          <p className="text-sm text-muted-foreground">
            לאחר קבלת תשלום, צרו ללקוח מייל וסיסמה ושלחו לו אותם. כל לקוח יכול להפיק דוח אחד, ואז החשבון ננעל.
          </p>
          <form
            className="grid gap-4 sm:grid-cols-2"
            onSubmit={(e) => {
              e.preventDefault();
              run(async () => {
                await create({ data: { email, password, note } });
                setEmail("");
                setNote("");
              }, `נוצר משתמש: ${email} / ${password}`);
            }}
          >
            <div className="space-y-1">
              <Label htmlFor="c-email">מייל</Label>
              <Input id="c-email" type="email" dir="ltr" required value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="c-pass">סיסמה (8 תווים לפחות)</Label>
              <div className="flex gap-2">
                <Input id="c-pass" dir="ltr" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} />
                <Button type="button" variant="outline" onClick={genPassword}><KeyRound className="size-4" /> יצירה</Button>
              </div>
            </div>
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="c-note">הערה (שם, מספר תשלום)</Label>
              <Input id="c-note" value={note} onChange={(e) => setNote(e.target.value)} />
            </div>
            <Button type="submit" disabled={busy} className="h-11 sm:col-span-2">יצירת משתמש</Button>
          </form>
          {msg && <p className="flex select-all items-center gap-2 rounded-md border border-border bg-secondary p-3 text-sm"><CheckCircle2 className="size-4 text-primary" />{msg}</p>}
        </section>

        <section className="space-y-4 rounded-lg border border-border bg-card p-6 shadow-lg shadow-primary/5">
          <h2 className="text-xl font-bold">לקוחות</h2>
          {list.isLoading ? (
            <p>טוען…</p>
          ) : !list.data?.length ? (
            <p className="text-muted-foreground">אין לקוחות עדיין.</p>
          ) : (
            <div className="overflow-x-auto rounded-md border border-border">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border bg-secondary text-right">
                    <th className="p-2">מייל</th>
                    <th className="p-2">הערה</th>
                    <th className="p-2">נוצר</th>
                    <th className="p-2">סטטוס</th>
                    <th className="p-2"></th>
                  </tr>
                </thead>
                <tbody>
                  {list.data.map((c) => (
                    <tr key={c.user_id} className="border-b border-border">
                      <td className="p-2" dir="ltr">{c.email}</td>
                      <td className="p-2">{c.note}</td>
                      <td className="p-2">{new Date(c.created_at).toLocaleDateString("he-IL")}</td>
                      <td className="p-2">
                        {c.report_used_at ? `הופק ${new Date(c.report_used_at).toLocaleDateString("he-IL")} — נעול` : "פעיל"}
                      </td>
                      <td className="flex gap-2 p-2">
                        {c.report_used_at && (
                          <Button size="sm" variant="outline" disabled={busy} onClick={() => run(() => reopen({ data: { userId: c.user_id } }), "החשבון נפתח לדוח נוסף")}>
                            <RotateCcw className="size-3.5" /> פתיחה מחדש
                          </Button>
                        )}
                        <Button
                          size="sm"
                          variant="destructive"
                          disabled={busy}
                          onClick={() => confirm(`למחוק את ${c.email}?`) && run(() => remove({ data: { userId: c.user_id } }), "נמחק")}
                        >
                            <Trash2 className="size-3.5" /> מחיקה
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </main>
    </div>
  );
}
