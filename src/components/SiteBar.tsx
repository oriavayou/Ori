import { Link, useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { Calculator, LogOut, Users } from "lucide-react";
import { Button } from "@/components/ui/button";
import logoAsset from "@/assets/maazan-logo.png.asset.json";

const logoUrl = logoAsset.url;

export function SiteBar({ email, isAdmin }: { email?: string | undefined; isAdmin?: boolean }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  async function signOut() {
    await qc.cancelQueries();
    qc.clear();
    await supabase.auth.signOut();
    navigate({ to: "/auth", replace: true });
  }
  return (
    <div className="flex h-16 items-center justify-between gap-3 border-b border-border bg-card px-4 text-sm shadow-sm sm:px-6">
      <span className="flex items-center gap-2 font-display text-base font-semibold"><img src={logoUrl} alt="לוגו מאזן ונגר" className="h-8 w-auto" />מאזן</span>
      <div className="flex items-center gap-2 sm:gap-4">
        {isAdmin && (
          <>
            <Link to="/app" className="flex items-center gap-2 rounded-md px-3 py-2 font-semibold text-muted-foreground transition-colors hover:bg-secondary hover:text-primary"><Calculator className="size-4" /><span className="hidden sm:inline">המחשבון</span></Link>
            <Link to="/admin" className="flex items-center gap-2 rounded-md px-3 py-2 font-semibold text-muted-foreground transition-colors hover:bg-secondary hover:text-primary"><Users className="size-4" /><span className="hidden sm:inline">ניהול לקוחות</span></Link>
          </>
        )}
        <span className="hidden opacity-70 sm:inline">{email}</span>
        <Button onClick={signOut} variant="ghost" size="sm"><LogOut className="size-4" /><span className="hidden sm:inline">יציאה</span></Button>
      </div>
    </div>
  );
}
