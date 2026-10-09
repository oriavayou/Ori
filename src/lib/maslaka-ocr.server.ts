/* קריאת דוח מסלקה סרוק (ללא טקסט) באמצעות מודל ראייה.
   המודל רק מעתיק ערכים מהדוח; הסיווג והביקורת מול סכום הדוח נעשים בדפדפן. */

const nullable = (t: string) => ({ type: [t, "null"] });

const PRODUCT = {
  type: "object",
  additionalProperties: false,
  properties: {
    section: { type: "string" },
    company: { type: "string" },
    productType: { type: "string" },
    policy: { type: "string" },
    status: { type: "string" },
    balance: nullable("number"),
    kitzba: nullable("number"),
    opened: { type: "string" },
    asOf: { type: "string" },
    nikuim: { type: "string" },
  },
  required: ["section", "company", "productType", "policy", "status", "balance", "kitzba", "opened", "asOf", "nikuim"],
};

const DEPOSIT = {
  type: "object",
  additionalProperties: false,
  properties: {
    policy: { type: "string" },
    valueDate: { type: "string" },
    salaryMonth: { type: "string" },
    amount: { type: "number" },
  },
  required: ["policy", "valueDate", "salaryMonth", "amount"],
};

export const MASLAKA_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    isMaslakaReport: { type: "boolean" },
    firstName: { type: "string" },
    lastName: { type: "string" },
    id: { type: "string" },
    statedTotals: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: { category: { type: "string" }, amount: { type: "number" } },
        required: ["category", "amount"],
      },
    },
    products: { type: "array", items: PRODUCT },
    deposits: { type: "array", items: DEPOSIT },
  },
  required: ["isMaslakaReport", "firstName", "lastName", "id", "statedTotals", "products", "deposits"],
};

const PROMPT = `זהו דוח "ריכוז מוצרים פנסיונים" של המסלקה הפנסיונית בישראל, שנשמר כתמונה. העתק ממנו ערכים במדויק, תו בתו. אל תחשב, אל תעגל ואל תשלים ערכים שאינם כתובים. ערך שאינו מופיע או אינו קריא: מחרוזת ריקה או null.
- isMaslakaReport: true רק אם זה דוח המסלקה הפנסיונית.
- firstName, lastName, id: מ"שם פרטי", "שם משפחה", "מס מזהה לקוח".
- statedTotals: מהטבלה בעמוד הראשון "ריכוז סכומי הצבירה לפי סוגי המוצרים" — שם כל קטגוריה בדיוק כפי שכתוב (למשל "קרנות פנסיה חדשות") והסכום שמתחתיה.
- products: לכל עמודת מוצר בטבלאות "פירוט המוצרים על פי סוג המוצר": section = כותרת הטבלה (למשל "קרנות פנסיה חדשות", "קרנות השתלמות", "קופות גמל", "ביטוח מנהלים"); company = שם חברה מנהלת; productType = סוג מוצר פנסיוני; policy = מספר פוליסה; status = סטטוס; balance = סה"כ חיסכון צבור; kitzba = "קיצבה חודשית לגיל פרישה ללא הפקדות כספים נוספות"; opened = תאריך פתיחת תכנית; asOf = תאריך נכונות נתונים; nikuim = מספר תיק ניכויים. תאריכים בפורמט DD/MM/YYYY כפי שכתוב. סכומים כמספר בלי ₪ ובלי פסיקים.
- deposits: לכל שורה בטבלאות "פירוט הפקדות": policy = מספר הפוליסה שבכותרת אותו עמוד/טבלה; valueDate = תאריך ערך (DD/MM/YYYY); salaryMonth = חודש משכורת (MM/YYYY); amount = סכום כל רכיבי ההפקדה בשורה (עובד, מעסיק, פיצויים וכו׳), ללא "שכר חודשי מדווח".`;

export async function readScannedMaslaka(pdfBase64: string, fileName: string) {
  const key = process.env["LOVABLE_API_KEY"];
  if (!key) throw new Error("שירות הקריאה אינו מוגדר");
  const res = await fetch("https://ai.gateway.lovable.dev/v1/responses", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${key}`,
      "Lovable-API-Key": key,
      "X-Lovable-AIG-SDK": "fetch",
    },
    body: JSON.stringify({
      model: "openai/gpt-6-astra",
      stream: true,
      store: false,
      reasoning: { effort: "low" },
      text: { format: { type: "json_schema", name: "maslaka", strict: true, schema: MASLAKA_SCHEMA } },
      input: [
        {
          role: "user",
          content: [
            { type: "input_text", text: PROMPT },
            { type: "input_file", filename: fileName || "maslaka.pdf", file_data: `data:application/pdf;base64,${pdfBase64}` },
          ],
        },
      ],
    }),
  });
  if (!res.ok || !res.body) {
    if (res.status === 402) throw new Error("נגמרו הקרדיטים לשירות הקריאה");
    if (res.status === 429) throw new Error("השירות עמוס כרגע — נסו שוב בעוד דקה");
    throw new Error(`קריאת הקובץ נכשלה (${res.status})`);
  }
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "", text = "", done = false;
  while (!done) {
    const r = await reader.read();
    if (r.done) break;
    buf += dec.decode(r.value, { stream: true });
    let i;
    while ((i = buf.indexOf("\n")) !== -1) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!line.startsWith("data:")) continue;
      const payload = line.slice(5).trim();
      if (payload === "[DONE]") { done = true; break; }
      try {
        const ev = JSON.parse(payload);
        if (ev.type === "response.output_text.delta") text += ev.delta;
        else if (ev.type === "response.failed" || ev.type === "error") throw new Error("קריאת הקובץ נכשלה");
        else if (ev.type === "response.completed") done = true;
      } catch (e) {
        if (e instanceof Error && e.message.startsWith("קריאת")) throw e;
      }
    }
  }
  if (!text) throw new Error("לא התקבלה קריאה מהקובץ");
  return JSON.parse(text);
}
