import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

/* ציבורי כמו המחשבון עצמו. הקובץ אינו נשמר — נשלח לקריאה ומוחזר. */
export const readScannedMaslakaFn = createServerFn({ method: "POST" })
  .inputValidator((d) =>
    z.object({ pdf: z.string().min(100).max(15_000_000), name: z.string().max(200) }).parse(d),
  )
  .handler(async ({ data }) => {
    const { readScannedMaslaka } = await import("./maslaka-ocr.server");
    try {
      return { ok: true as const, result: await readScannedMaslaka(data.pdf, data.name) };
    } catch (e) {
      return { ok: false as const, error: e instanceof Error ? e.message : "קריאת הקובץ נכשלה" };
    }
  });
