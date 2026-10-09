import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import logoAsset from "@/assets/maazan-logo.png.asset.json";

const logoUrl = logoAsset.url;

export const Route = createFileRoute("/auth")({
  head: () => ({
    meta: [
      { title: "כניסה — מאזן" },
      { name: "description", content: "כניסה למערכת מאזן לחישובי איזון משאבים וזכויות פנסיוניות." },
      { property: "og:title", content: "כניסה — מאזן" },
      { property: "og:description", content: "כניסה למערכת מאזן לחישובי איזון משאבים וזכויות פנסיוניות." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: AuthPage,
});

function AuthPage() {
  const navigate = useNavigate();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      if (data.user) navigate({ to: "/admin", replace: true });
    });
  }, [navigate]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setBusy(false);
    if (error) return setMsg("מייל או סיסמה שגויים");
    navigate({ to: "/admin", replace: true });
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-4">
      <div className="w-full max-w-sm">
        <form onSubmit={submit} className="space-y-5">
          <div>
            <img src={logoUrl} alt="מאזן ונגר" className="mb-6 h-8 w-auto" />
            <h1 className="text-xl font-semibold">כניסה</h1>
            <p className="mt-1 text-sm text-muted-foreground">למשתמשים מורשים בלבד.</p>
          </div>
          <div className="space-y-1">
            <Label htmlFor="email">מייל</Label>
            <Input className="h-11" id="email" type="email" dir="ltr" required value={email} onChange={(e) => setEmail(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="password">סיסמה</Label>
            <Input className="h-11" id="password" type="password" dir="ltr" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} />
          </div>
          {msg && <p className="text-sm">{msg}</p>}
          <Button type="submit" className="h-11 w-full" disabled={busy}>
            {busy ? "מתחבר…" : "כניסה"}
          </Button>
        </form>
      </div>
    </div>
  );
}
