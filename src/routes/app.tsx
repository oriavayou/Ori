import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useRef } from "react";
import { getPublicSite } from "@/lib/access.functions";
import { readScannedMaslakaFn } from "@/lib/maslaka-ocr.functions";

export const Route = createFileRoute("/app")({
  head: () => ({
    meta: [
      { title: "המחשבון — מאזן" },
      { name: "description", content: "מחשבון איזון משאבים לפנסיה מקיפה ומשלימה." },
      { property: "og:title", content: "המחשבון — מאזן" },
      { property: "og:description", content: "מחשבון איזון משאבים לפנסיה מקיפה ומשלימה." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  loader: () => getPublicSite(),
  component: AppPage,
});

function AppPage() {
  const { html } = Route.useLoaderData();
  const frame = useRef<HTMLIFrameElement>(null);
  useEffect(() => {
    function onMsg(e: MessageEvent) {
      const win = frame.current?.contentWindow;
      if (!win || e.source !== win) return;
      if (e.data?.type === "nk-request-unlock") {
        win.postMessage({ type: "nk-show-admin-preview" }, "*");
      } else if (e.data?.type === "nk-admin-preview-approved") {
        win.postMessage({ type: "nk-unlock" }, "*");
      } else if (e.data?.type === "nk-ocr-request") {
        const { reqId, pdf, name } = e.data;
        readScannedMaslakaFn({ data: { pdf, name } })
          .then((r) => win.postMessage({ type: "nk-ocr-result", reqId, ...r }, "*"))
          .catch(() => win.postMessage({ type: "nk-ocr-result", reqId, ok: false, error: "קריאת הקובץ הסרוק נכשלה" }, "*"));
      }
    }
    window.addEventListener("message", onMsg);
    return () => window.removeEventListener("message", onMsg);
  }, []);
  return (
    <iframe ref={frame} srcDoc={html} title="מאזן — מחשבון" className="block h-screen w-full border-0 bg-background" />
  );
}
